import SwiftUI
import SwiftData

struct ServerConfigView: View {
    @State private var serverURL = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: ConnectionStatus = .none
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var selectedAccountId: String? = nil
    @State private var accounts: [SavedAccount] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var onConnected: () -> Void
    var embedsInOwnStack: Bool = true

    enum ConnectionStatus {
        case none, testing, success, failure
    }

    var body: some View {
        Group {
            if embedsInOwnStack {
                NavigationStack {
                    contentView
                        .toolbar(.hidden, for: .navigationBar)
                }
            } else {
                contentView
                    .navigationTitle("切换服务器")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .background(Color(.systemGroupedBackground))
        .alert("连接错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo 区域
            VStack(spacing: 16) {
                Image("logo")
                    .resizable().scaledToFit().frame(width: 80, height: 80)

                Text("NowenReaderLite")
                    .font(.title.weight(.bold))

                Text("基于 nowen-reader 的轻量级客户端")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // 输入区域
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                        .font(.title3)

                    TextField("https://your-server.com", text: $serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body)
                }
                .padding(16)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(borderColor, lineWidth: 1)
                )

                APIKeySecureField(
                    value: $apiKey,
                    isRevealed: $showsAPIKey,
                    placeholder: "API Key（可选）"
                )
                .padding(16)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.gray.opacity(0.3), lineWidth: 1)
                )

                // 绑定账号选择
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("绑定账号（可选）")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(accounts) { account in
                                    Button {
                                        selectedAccountId = selectedAccountId == account.id ? nil : account.id
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: selectedAccountId == account.id ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedAccountId == account.id ? Color.accentColor : .secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(account.alias)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.primary)
                                                Text(account.username)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(selectedAccountId == account.id ? Color.accentColor.opacity(0.1) : Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                // 连接状态
                if connectionStatus == .testing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在测试连接...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if connectionStatus == .success {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("连接成功")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else if connectionStatus == .failure {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("连接或认证失败，请检查配置")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // 操作按钮
            VStack(spacing: 12) {
                Button(action: testConnection) {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.small)
                        }
                        Text("测试连接")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(serverURL.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(serverURL.isEmpty || isTestingConnection)

                Button(action: connectAndContinue) {
                    Text("连接并继续")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(connectionStatus == .success ? Color.accentColor : Color.gray.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(connectionStatus != .success)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .onAppear {
            loadAccounts()
        }
        .onChange(of: serverURL) { _, _ in
            connectionStatus = .none
        }
        .onChange(of: apiKey) { _, _ in
            connectionStatus = .none
        }
        .onDisappear {
            apiKey = ""
        }
    }

    private var borderColor: Color {
        switch connectionStatus {
        case .success: return .green.opacity(0.5)
        case .failure: return .red.opacity(0.5)
        default: return .gray.opacity(0.3)
        }
    }

    private func loadAccounts() {
        accounts = APIClient.shared.fetchAllAccounts(context: modelContext)
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatus = .testing
        Task {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let success: Bool
            if key.isEmpty {
                success = await APIClient.shared.testConnection(serverURL)
            } else {
                do {
                    _ = try await APIClient.shared.testAPIKey(key, serverURL: serverURL)
                    success = true
                } catch {
                    success = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            isTestingConnection = false
            connectionStatus = success ? .success : .failure
        }
    }

    private func connectAndContinue() {
        let trimmed = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        APIClient.shared.setServerURL(trimmed)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !APIClient.shared.setAPIKey(key, for: trimmed) {
            errorMessage = "无法将 API Key 保存到本机 Keychain。"
            showError = true
            return
        }
        Task {
            // 首次配置服务器时 isNetworkReachable 为 false（init 时 serverURL 为空未启动监测）
            // 用户已通过"测试连接"验证可达，直接标记为可达
            APIClient.shared.setNetworkReachable(true)

            await APIClient.shared.checkAuth()

            // Save or update server record
            let descriptor = FetchDescriptor<ServerRecord>(
                predicate: #Predicate<ServerRecord> { $0.url == trimmed }
            )
            // 查找绑定的账号对象
            var boundAccount: SavedAccount? = nil
            if let selectedId = selectedAccountId {
                let acctDesc = FetchDescriptor<SavedAccount>(predicate: #Predicate { $0.id == selectedId })
                boundAccount = modelContext.fetchOrLog(acctDesc, label: "查找绑定账号").first
            }

            if let existing = modelContext.fetchOrLog(descriptor, label: "查找已有服务器记录").first {
                existing.lastUsed = Date()
                existing.username = APIClient.shared.currentUser?.username
                existing.boundAccount = boundAccount
            } else {
                let record = ServerRecord(url: trimmed, username: APIClient.shared.currentUser?.username)
                record.boundAccount = boundAccount
                modelContext.insert(record)
            }
            modelContext.saveOrLog()

            // 如果选了绑定账号且当前未登录，尝试自动登录
            if !APIClient.shared.isLoggedIn,
               !APIClient.shared.hasConfiguredAPIKey,
               let accountId = selectedAccountId {
                let all = modelContext.fetchOrLog(FetchDescriptor<SavedAccount>(), label: "自动登录查询账号")
                if let account = all.first(where: { $0.id == accountId }) {
                    _ = try? await APIClient.shared.quickLogin(account: account)
                }
            }

            dismiss()
            onConnected()
        }
    }
}

struct APIKeySecureField: View {
    @Binding var value: String
    @Binding var isRevealed: Bool
    let placeholder: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Group {
                if isRevealed {
                    TextField(placeholder, text: $value)
                } else {
                    SecureField(placeholder, text: $value)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(isRevealed ? "隐藏 API Key" : "显示 API Key")
        }
    }
}
