import SwiftUI
import SwiftData

struct ServerListView: View {
    @Query(sort: [SortDescriptor(\ServerRecord.lastUsed, order: .reverse)])
    private var servers: [ServerRecord]
    @Query(sort: [SortDescriptor(\SavedAccount.alias)])
    private var accounts: [SavedAccount]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api

    @State private var showAddServer = false
    @State private var isSwitching = false
    @State private var switchingServerId: String? = nil
    @State private var showTimeoutAlert = false
    @State private var timeoutServerURL = ""
    @State private var editingServer: ServerRecord? = nil
    private let switchTimeout: TimeInterval = 5

    var body: some View {
        List {
            if servers.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("暂无保存的服务器")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("点击右上角 + 添加服务器")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        Button {
                            switchToServer(server)
                        } label: {
                            HStack(spacing: 12) {
                                let isHTTPS = server.url.lowercased().hasPrefix("https://")
                                Image(systemName: isHTTPS ? "lock.fill" : "lock.open.fill")
                                    .font(.caption)
                                    .foregroundStyle(isHTTPS ? .green : .red)
                                Image(systemName: "server.rack")
                                    .font(.title3)
                                    .foregroundStyle(api.serverURL == server.url ? Color.accentColor : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.url)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let account = server.boundAccount {
                                        HStack(spacing: 4) {
                                            Image(systemName: "person.fill")
                                                .font(.caption2)
                                            Text(account.alias)
                                                .font(.caption)
                                        }
                                        .foregroundStyle(.secondary)
                                    } else if let username = server.username, !username.isEmpty {
                                        Text(username)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if isSwitching && switchingServerId == server.url {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if api.serverURL == server.url {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(isSwitching)
                        .contextMenu {
                            Button {
                                editingServer = server
                            } label: {
                                Label("绑定账号", systemImage: "person.badge.key")
                            }
                        }
                    }
                    .onDelete(perform: deleteServers)
                }
            }
        }
        .navigationTitle("服务器列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showAddServer) {
            ServerConfigView(onConnected: {}, embedsInOwnStack: false)
        }
        .alert("连接超时", isPresented: $showTimeoutAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("无法连接到 \(timeoutServerURL)，已自动切回之前的服务器")
        }
        .sheet(item: $editingServer) { server in
            ServerBindAccountSheet(
                server: server,
                currentBoundId: server.boundAccountId,
                accounts: accounts,
                onSave: { newBoundId in
                    if let id = newBoundId {
                        server.boundAccount = account(for: id)
                    } else {
                        server.boundAccount = nil
                    }
                    modelContext.saveOrLog()
                }
            )
        }
    }

    // MARK: - Helpers

    private func account(for id: String?) -> SavedAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    private func switchToServer(_ record: ServerRecord) {
        guard !isSwitching else { return }
        guard APIClient.shared.serverURL != record.url else { return }

        let previousURL = APIClient.shared.serverURL
        let previousUser = APIClient.shared.currentUser
        let previousIsLoggedIn = APIClient.shared.isLoggedIn

        isSwitching = true
        switchingServerId = record.url
        record.lastUsed = Date()

        // 清除旧服务器的 cookie 和本地缓存
        APIClient.shared.clearCookiesForCurrentServer()
        try? modelContext.delete(model: CachedComic.self)
        modelContext.saveOrLog()

        APIClient.shared.setServerURL(record.url)

        Task {
            // 带超时的切换逻辑
            let result = await withTimeout(switchTimeout) {
                // 如果有绑定账号，尝试用它自动登录
                if let account = record.boundAccount {
                    do {
                        _ = try await APIClient.shared.quickLogin(account: account)
                        await MainActor.run {
                            record.username = account.username
                        }
                        self.modelContext.saveOrLog(label: "自动登录成功后保存")
                        return true
                    } catch {
                        AppLogger.error("自动登录失败: \(error)")
                        return false
                    }
                }

                // 无绑定账号：检查服务器是否可达 + 是否已有登录态
                await APIClient.shared.checkAuth()
                await MainActor.run {
                    record.username = APIClient.shared.currentUser?.username
                }
                self.modelContext.saveOrLog(label: "更新服务器用户名")
                return APIClient.shared.isLoggedIn
            }

            await MainActor.run {
                switch result {
                case .success:
                    break
                case .timeout:
                    timeoutServerURL = record.url
                    showTimeoutAlert = true
                    rollbackTo(previousURL: previousURL, previousUser: previousUser, isLoggedIn: previousIsLoggedIn)
                case .failure:
                    // 登录失败或服务器不可达，回退到之前的服务器
                    rollbackTo(previousURL: previousURL, previousUser: previousUser, isLoggedIn: previousIsLoggedIn)
                }
                isSwitching = false
                switchingServerId = nil
            }
        }
    }

    private func rollbackTo(previousURL: String, previousUser: AuthUser?, isLoggedIn: Bool) {
        APIClient.shared.clearCookiesForCurrentServer()
        APIClient.shared.setServerURL(previousURL)
        APIClient.shared.currentUser = previousUser
        APIClient.shared.isLoggedIn = isLoggedIn

        Task {
            // cookie 已丢失，尝试用绑定账号重新登录
            if let record = servers.first(where: { $0.url == previousURL }),
               let account = record.boundAccount {
                do {
                    _ = try await APIClient.shared.quickLogin(account: account)
                    return
                } catch {
                    AppLogger.error("回滚后自动登录失败: \(error)")
                }
            }
            // 无绑定账号或登录失败，仅检查当前状态
            await APIClient.shared.checkAuth()
        }
    }

    private enum TimeoutResult { case success, failure, timeout }

    /// 带超时的异步执行
    private func withTimeout(_ seconds: TimeInterval, operation: @escaping () async -> Bool) async -> TimeoutResult {
        await withTaskGroup(of: TimeoutResult.self) { group in
            group.addTask {
                let ok = await operation()
                return ok ? .success : .failure
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timeout
            }
            guard let first = await group.next() else {
                group.cancelAll()
                return .timeout
            }
            group.cancelAll()
            return first
        }
    }

    private func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            let server = servers[index]
            if server.url == APIClient.shared.serverURL { continue }
            modelContext.delete(server)
        }
        modelContext.saveOrLog()
    }
}

// MARK: - 服务器绑定账号 Sheet

struct ServerBindAccountSheet: View {
    let server: ServerRecord
    let currentBoundId: String?
    let accounts: [SavedAccount]
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?

    var body: some View {
        NavigationStack {
            List {
                Section("选择绑定账号") {
                    Button {
                        selectedId = nil
                    } label: {
                        HStack {
                            Image(systemName: selectedId == nil ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedId == nil ? Color.accentColor : .secondary)
                            Text("不绑定")
                                .foregroundStyle(.primary)
                        }
                    }

                    ForEach(accounts) { account in
                        Button {
                            selectedId = account.id
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.12))
                                        .frame(width: 32, height: 32)
                                    Text(String(account.alias.prefix(1)).uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.alias)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(account.username)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedId == account.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                if accounts.isEmpty {
                    Section {
                        Text("暂无已保存的账号，请先到 设置 → 账号管理 添加")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("绑定账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(selectedId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedId = currentBoundId
            }
        }
    }
}
