import SwiftUI
import SwiftData

struct ServerListView: View {
    @Query(sort: [SortDescriptor(\ServerRecord.lastUsed, order: .reverse)])
    private var servers: [ServerRecord]

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var api = APIClient.shared
    @Environment(\.dismiss) private var dismiss

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

                                    if let accountId = server.boundAccountId,
                                       let account = findAccount(id: accountId) {
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
                                        .scaleEffect(0.8)
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
                accounts: allAccounts(),
                onSave: { newBoundId in
                    if let id = newBoundId {
                        let desc = FetchDescriptor<SavedAccount>(predicate: #Predicate { $0.id == id })
                        server.boundAccount = try? modelContext.fetch(desc).first
                    } else {
                        server.boundAccount = nil
                    }
                    modelContext.saveOrLog()
                }
            )
        }
    }

    // MARK: - Helpers

    private func findAccount(id: String) -> SavedAccount? {
        let all = (try? modelContext.fetch(FetchDescriptor<SavedAccount>())) ?? []
        return all.first { $0.id == id }
    }

    private func allAccounts() -> [SavedAccount] {
        (try? modelContext.fetch(FetchDescriptor<SavedAccount>())) ?? []
    }

    private func switchToServer(_ record: ServerRecord) {
        guard !isSwitching else { return }
        guard api.serverURL != record.url else { return }

        let previousURL = api.serverURL
        let previousUser = api.currentUser

        isSwitching = true
        switchingServerId = record.url
        record.lastUsed = Date()

        // 清除旧服务器的 cookie 和本地缓存
        api.clearCookiesForCurrentServer()
        try? modelContext.delete(model: CachedComic.self)
        modelContext.saveOrLog()

        api.setServerURL(record.url)

        Task {
            // 带超时的切换逻辑
            let result = await withTimeout(switchTimeout) {
                // 如果有绑定账号，尝试用它自动登录
                if let accountId = record.boundAccountId,
                   let account = self.findAccount(id: accountId) {
                    do {
                        _ = try await self.api.quickLogin(account: account)
                        await MainActor.run {
                            record.username = account.username
                        }
                        try? self.modelContext.save()
                        return true
                    } catch {
                        AppLogger.error("自动登录失败: \(error)")
                    }
                }

                // 无绑定账号或自动登录失败
                await self.api.checkAuth()
                await MainActor.run {
                    record.username = self.api.currentUser?.username
                }
                try? self.modelContext.save()
                return true
            }

            await MainActor.run {
                switch result {
                case .success:
                    break
                case .timeout:
                    timeoutServerURL = record.url
                    showTimeoutAlert = true
                    api.clearCookiesForCurrentServer()
                    api.setServerURL(previousURL)
                    api.currentUser = previousUser
                    api.isLoggedIn = previousUser != nil
                    Task { await api.checkAuth() }
                case .failure:
                    // 操作完成但登录失败，回退到之前的服务器
                    api.clearCookiesForCurrentServer()
                    api.setServerURL(previousURL)
                    api.currentUser = previousUser
                    api.isLoggedIn = previousUser != nil
                    Task { await api.checkAuth() }
                }
                isSwitching = false
                switchingServerId = nil
            }
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
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            let server = servers[index]
            if server.url == api.serverURL { continue }
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
