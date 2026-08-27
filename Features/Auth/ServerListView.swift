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
    @State private var routeEditingServer: ServerRecord? = nil
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
                            if api.matchesServerProfile(server.url) {
                                routeEditingServer = server
                            } else {
                                switchToServer(server)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                let securityURL = api.matchesServerProfile(server.url)
                                    ? api.serverURL
                                    : server.url
                                let isHTTPS = securityURL.lowercased().hasPrefix("https://")
                                Image(systemName: isHTTPS ? "lock.fill" : "lock.open.fill")
                                    .font(.caption)
                                    .foregroundStyle(isHTTPS ? .green : .red)
                                Image(systemName: "server.rack")
                                    .font(.title3)
                                    .foregroundStyle(api.matchesServerProfile(server.url) ? Color.accentColor : .secondary)

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

                                    if let backupURL = server.backupURL, !backupURL.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                            Text(server.routeMode.title)
                                            if api.matchesServerProfile(server.url) {
                                                Text("· \(api.activeRouteTitle)")
                                                if api.activeRouteIsLocal {
                                                    Text("· 内网")
                                                }
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    }

                                    if api.matchesServerProfile(server.url),
                                       api.hasConfiguredAPIKey {
                                        Label("API Key", systemImage: "key.horizontal")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if isSwitching && switchingServerId == server.url {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if api.matchesServerProfile(server.url) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(isSwitching)
                        .contextMenu {
                            Button {
                                routeEditingServer = server
                            } label: {
                                Label("连接设置", systemImage: "point.3.connected.trianglepath.dotted")
                            }
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
        .sheet(item: $routeEditingServer) { server in
            ServerRouteSettingsSheet(
                primaryURL: server.url,
                initialBackupURL: server.backupURL ?? "",
                initialMode: server.routeMode,
                initialHasAPIKey: KeychainHelper.hasAPIKey(for: server.url),
                isCurrentServer: api.matchesServerProfile(server.url),
                reservedPrimaryURLs: Set(
                    servers
                        .filter { $0.url != server.url }
                        .map(\.url)
                ),
                onSave: { primaryURL, backupURL, mode in
                    let previousPrimaryURL = server.url
                    let wasCurrentServer = api.matchesServerProfile(previousPrimaryURL)
                    if wasCurrentServer, previousPrimaryURL != primaryURL {
                        api.preparePrimaryRouteChange(
                            from: previousPrimaryURL,
                            to: primaryURL
                        )
                    }
                    server.url = primaryURL
                    server.backupURL = backupURL
                    server.routeMode = mode
                    modelContext.saveOrLog(label: "保存服务器线路")
                    guard wasCurrentServer else { return }
                    api.configureServerRoutes(
                        primaryURL: primaryURL,
                        backupURL: backupURL,
                        mode: mode
                    )
                    Task {
                        let reachable = await api.selectReachableRoute()
                        if reachable {
                            await api.checkAuth()
                        }
                    }
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
        guard !APIClient.shared.matchesServerProfile(record.url) else { return }

        let previousRecord = servers.first {
            APIClient.shared.matchesServerProfile($0.url)
        }
        let previousURL = APIClient.shared.primaryServerURL
        let previousBackupURL = previousRecord?.backupURL
        let previousRouteMode = previousRecord?.routeMode ?? .automatic
        let previousUser = APIClient.shared.currentUser
        let previousIsLoggedIn = APIClient.shared.isLoggedIn

        isSwitching = true
        switchingServerId = record.url
        record.lastUsed = Date()

        // 清除旧服务器的 cookie 和本地缓存
        APIClient.shared.clearCookiesForCurrentServer()
        try? modelContext.delete(model: CachedComic.self)
        modelContext.saveOrLog()

        APIClient.shared.configureServerRoutes(
            primaryURL: record.url,
            backupURL: record.backupURL,
            mode: record.routeMode
        )

        Task {
            // 带超时的切换逻辑
            let result = await withTimeout(switchTimeout) {
                guard await APIClient.shared.selectReachableRoute() else {
                    return false
                }
                if APIClient.shared.hasConfiguredAPIKey {
                    await APIClient.shared.checkAuth()
                    await MainActor.run {
                        record.username = APIClient.shared.currentUser?.username
                    }
                    self.modelContext.saveOrLog(label: "API Key 登录后保存")
                    return APIClient.shared.isLoggedIn
                }
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
                    rollbackTo(
                        previousURL: previousURL,
                        previousBackupURL: previousBackupURL,
                        previousRouteMode: previousRouteMode,
                        previousUser: previousUser,
                        isLoggedIn: previousIsLoggedIn
                    )
                case .failure:
                    // 登录失败或服务器不可达，回退到之前的服务器
                    rollbackTo(
                        previousURL: previousURL,
                        previousBackupURL: previousBackupURL,
                        previousRouteMode: previousRouteMode,
                        previousUser: previousUser,
                        isLoggedIn: previousIsLoggedIn
                    )
                }
                isSwitching = false
                switchingServerId = nil
            }
        }
    }

    private func rollbackTo(
        previousURL: String,
        previousBackupURL: String?,
        previousRouteMode: ServerRouteMode,
        previousUser: AuthUser?,
        isLoggedIn: Bool
    ) {
        APIClient.shared.clearCookiesForCurrentServer()
        APIClient.shared.configureServerRoutes(
            primaryURL: previousURL,
            backupURL: previousBackupURL,
            mode: previousRouteMode
        )
        APIClient.shared.currentUser = previousUser
        APIClient.shared.isLoggedIn = isLoggedIn

        Task {
            if APIClient.shared.hasConfiguredAPIKey {
                await APIClient.shared.checkAuth()
                if APIClient.shared.isLoggedIn { return }
            }
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
            if APIClient.shared.matchesServerProfile(server.url) { continue }
            _ = KeychainHelper.deleteAPIKey(for: server.url)
            modelContext.delete(server)
        }
        modelContext.saveOrLog()
    }
}

// MARK: - 服务器连接设置

private enum ServerAPIKeyUpdate {
    case unchanged
    case replace(String)
    case remove
}

private struct ServerRouteSettingsSheet: View {
    let initialPrimaryURL: String
    let initialHasAPIKey: Bool
    let isCurrentServer: Bool
    let reservedPrimaryURLs: Set<String>
    let onSave: (String, String?, ServerRouteMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api
    @State private var primaryURL: String
    @State private var backupURL: String
    @State private var routeMode: ServerRouteMode
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var removesStoredAPIKey = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var errorAllowsSaving = false

    init(
        primaryURL: String,
        initialBackupURL: String,
        initialMode: ServerRouteMode,
        initialHasAPIKey: Bool,
        isCurrentServer: Bool,
        reservedPrimaryURLs: Set<String>,
        onSave: @escaping (String, String?, ServerRouteMode) -> Void
    ) {
        self.initialPrimaryURL = primaryURL
        self.initialHasAPIKey = initialHasAPIKey
        self.isCurrentServer = isCurrentServer
        self.reservedPrimaryURLs = reservedPrimaryURLs
        self.onSave = onSave
        _primaryURL = State(initialValue: primaryURL)
        _backupURL = State(initialValue: initialBackupURL)
        _routeMode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("线路模式") {
                    Picker("线路模式", selection: $routeMode) {
                        ForEach(ServerRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("https://主线路地址", text: $primaryURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("主线路")
                } footer: {
                    Text("请填写最终访问地址。跨域名、协议或端口重定向可能移除 API Key 认证头。")
                }

                Section {
                    TextField("https://备用地址", text: $backupURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("备用线路")
                } footer: {
                    Text("客户端会比较两条线路的登录用户与书库。验证一致后，自动模式会在局域网中优先使用内网线路。")
                }

                ServerAPIKeySettingsSection(
                    initialHasAPIKey: initialHasAPIKey,
                    apiKey: $apiKey,
                    showsAPIKey: $showsAPIKey,
                    removesStoredAPIKey: $removesStoredAPIKey
                )

                if isCurrentServer {
                    Section("当前连接") {
                        LabeledContent("正在使用") {
                            HStack(spacing: 5) {
                                if api.activeRouteIsLocal {
                                    Image(systemName: "wifi")
                                }
                                Text(api.activeRouteTitle)
                            }
                        }
                        if api.backupServerURL != nil {
                            HStack(spacing: 12) {
                                Text("线路验证")
                                Spacer(minLength: 8)
                                ServerRouteVerificationStatusView(
                                    verification: api.routeVerification
                                )
                                Button {
                                    Task {
                                        _ = await api.refreshRouteVerification()
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .disabled(api.routeVerification == .checking)
                                .accessibilityLabel("重新验证线路")
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        LabeledContent("认证方式") {
                            Text(api.activeAuthenticationTitle)
                        }
                    }
                }
            }
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("正在验证连接")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .alert("无法保存连接设置", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("取消", role: .cancel) {}
                if errorAllowsSaving {
                    Button("仍然保存") {
                        guard let normalizedPrimaryURL else { return }
                        finishSave(
                            primaryURL: normalizedPrimaryURL,
                            backupURL: normalizedBackupURL
                        )
                    }
                }
            } message: {
                Text(errorMessage ?? "请检查地址后重试。")
            }
            .onChange(of: apiKey) { _, newValue in
                if !newValue.isEmpty {
                    removesStoredAPIKey = false
                }
            }
            .onDisappear {
                apiKey = ""
            }
            .task {
                guard isCurrentServer,
                      api.backupServerURL != nil,
                      api.routeVerification != .checking else {
                    return
                }
                _ = await api.refreshRouteVerification()
            }
        }
    }

    private var normalizedPrimaryURL: String? {
        normalizedServerURL(primaryURL)
    }

    private var normalizedBackupURL: String? {
        let trimmed = backupURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty,
              trimmed != normalizedPrimaryURL,
              normalizedServerURL(trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    private func normalizedServerURL(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil else {
            return nil
        }
        return trimmed
    }

    private var canSave: Bool {
        guard normalizedPrimaryURL != nil else { return false }
        let isEmpty = backupURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            return routeMode != .backup
        }
        return normalizedBackupURL != nil
    }

    private func save() {
        guard let normalizedPrimaryURL else { return }
        if reservedPrimaryURLs.contains(normalizedPrimaryURL) {
            errorAllowsSaving = false
            errorMessage = "该主线路地址已存在于服务器列表中。"
            return
        }
        let isEmpty = backupURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEmpty || normalizedBackupURL != nil else { return }
        isSaving = true
        Task {
            var verification: ServerRouteVerification = .notConfigured
            if let normalizedBackupURL {
                verification = await api.verifyServerPair(
                    primaryURL: normalizedPrimaryURL,
                    backupURL: normalizedBackupURL,
                    apiKeyOverride: routeVerificationAPIKeyOverride
                )
                if verification == .mismatch {
                    isSaving = false
                    errorAllowsSaving = false
                    errorMessage = "主线路与备用线路属于不同的 Nowen Reader 服务，不能共享认证或自动切换。"
                    return
                }
            }

            do {
                if case .replace(let key) = apiKeyUpdate {
                    try await validateAPIKey(key)
                }
            } catch {
                isSaving = false
                errorAllowsSaving = false
                errorMessage = error.localizedDescription
                return
            }

            switch verification {
            case .unavailable:
                isSaving = false
                errorAllowsSaving = true
                errorMessage = "目前无法同时连接两条线路，因此无法确认它们是否属于同一服务器。"
                return
            case .authenticationRequired:
                isSaving = false
                errorAllowsSaving = true
                errorMessage = "当前没有可用于两条线路的登录凭据。保存后会在登录成功时自动验证。"
                return
            case .authenticationFailed:
                isSaving = false
                errorAllowsSaving = true
                errorMessage = "当前 API Key 或登录状态无法同时通过两条线路认证。请检查线路地址和认证信息。"
                return
            default:
                break
            }
            isSaving = false
            finishSave(
                primaryURL: normalizedPrimaryURL,
                backupURL: normalizedBackupURL
            )
        }
    }

    private var apiKeyUpdate: ServerAPIKeyUpdate {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .replace(trimmed) }
        if removesStoredAPIKey { return .remove }
        return .unchanged
    }

    private var routeVerificationAPIKeyOverride: String? {
        switch apiKeyUpdate {
        case .unchanged:
            guard normalizedPrimaryURL != initialPrimaryURL else { return nil }
            return KeychainHelper.readAPIKey(for: initialPrimaryURL)
        case .replace(let key):
            return key
        case .remove:
            return ""
        }
    }

    private func validateAPIKey(_ key: String) async throws {
        let candidates = Array(Set(
            [normalizedPrimaryURL, normalizedBackupURL, isCurrentServer ? api.serverURL : nil]
                .compactMap { $0 }
        ))
        var lastError: Error = APIError.networkError
        for candidate in candidates {
            do {
                _ = try await api.testAPIKey(key, serverURL: candidate)
                return
            } catch APIError.invalidAPIKey {
                lastError = APIError.invalidAPIKey
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func finishSave(primaryURL: String, backupURL: String?) {
        let keychainSaved: Bool
        switch apiKeyUpdate {
        case .unchanged:
            if primaryURL != initialPrimaryURL,
               let storedKey = KeychainHelper.readAPIKey(for: initialPrimaryURL) {
                keychainSaved = KeychainHelper.saveAPIKey(storedKey, for: primaryURL)
            } else {
                keychainSaved = true
            }
        case .replace(let key):
            keychainSaved = api.setAPIKey(key, for: primaryURL)
        case .remove:
            keychainSaved = KeychainHelper.deleteAPIKey(for: primaryURL)
                && KeychainHelper.deleteAPIKey(for: initialPrimaryURL)
        }
        guard keychainSaved else {
            errorAllowsSaving = false
            errorMessage = "无法将 API Key 保存到本机 Keychain。"
            return
        }
        if primaryURL != initialPrimaryURL {
            _ = KeychainHelper.deleteAPIKey(for: initialPrimaryURL)
        }
        onSave(primaryURL, backupURL, routeMode)
        dismiss()
    }
}

private struct ServerRouteVerificationStatusView: View {
    let verification: ServerRouteVerification

    var body: some View {
        switch verification {
        case .verified:
            Label("同一服务器", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .mismatch:
            Label("服务器不一致", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在验证")
            }
        case .authenticationRequired:
            Text("登录后验证")
                .foregroundStyle(.secondary)
        case .authenticationFailed:
            Label("认证失败", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
        case .unavailable:
            Text("暂时无法验证")
                .foregroundStyle(.secondary)
        case .notConfigured, .unverified:
            Text("等待验证")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ServerAPIKeySettingsSection: View {
    let initialHasAPIKey: Bool
    @Binding var apiKey: String
    @Binding var showsAPIKey: Bool
    @Binding var removesStoredAPIKey: Bool

    var body: some View {
        Section {
            APIKeySecureField(
                value: $apiKey,
                isRevealed: $showsAPIKey,
                placeholder: initialHasAPIKey ? "输入新 Key 以替换" : "nwr_..."
            )

            if initialHasAPIKey && apiKey.isEmpty && !removesStoredAPIKey {
                Label("已配置 API Key", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            if initialHasAPIKey && !removesStoredAPIKey {
                Button("从本机移除 API Key", role: .destructive) {
                    apiKey = ""
                    removesStoredAPIKey = true
                }
            } else if removesStoredAPIKey {
                Label("保存后改用 Cookie 登录", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("请在服务端网页创建或撤销 Key。完整 Key 仅保存在本机 Keychain，并同时用于两条线路。")
        }
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
