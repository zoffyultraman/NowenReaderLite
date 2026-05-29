import SwiftUI
import SwiftData

struct ServerConfigView: View {
    @State private var serverURL = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: ConnectionStatus = .none
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedAccountId: String? = nil
    @State private var accounts: [SavedAccount] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var api = APIClient.shared
    var onConnected: () -> Void
    var embedsInOwnStack: Bool = true

    enum ConnectionStatus {
        case none, testing, success, failure
    }

    var body: some View {
        contentView
            .if(embedsInOwnStack) { view in
                NavigationStack {
                    view.navigationBarHidden(true)
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

                // 绑定账号选择
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("绑定账号（可选）")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
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
                    }
                }

                // 连接状态
                if connectionStatus == .testing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
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
                        Text("连接失败，请检查地址")
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
                                .scaleEffect(0.8)
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
    }

    private var borderColor: Color {
        switch connectionStatus {
        case .success: return .green.opacity(0.5)
        case .failure: return .red.opacity(0.5)
        default: return .gray.opacity(0.3)
        }
    }

    private func loadAccounts() {
        accounts = api.fetchAllAccounts(context: modelContext)
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatus = .testing
        Task {
            let success = await api.testConnection(serverURL)
            isTestingConnection = false
            connectionStatus = success ? .success : .failure
        }
    }

    private func connectAndContinue() {
        let trimmed = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        api.setServerURL(trimmed)
        Task {
            await api.checkAuth()
            // Save or update server record
            let descriptor = FetchDescriptor<ServerRecord>(
                predicate: #Predicate<ServerRecord> { $0.url == trimmed }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.lastUsed = Date()
                existing.username = api.currentUser?.username
                existing.boundAccountId = selectedAccountId
            } else {
                let record = ServerRecord(url: trimmed, username: api.currentUser?.username)
                record.boundAccountId = selectedAccountId
                modelContext.insert(record)
            }
            try? modelContext.save()

            // 如果选了绑定账号且当前未登录，尝试自动登录
            if !api.isLoggedIn, let accountId = selectedAccountId {
                let all = (try? modelContext.fetch(FetchDescriptor<SavedAccount>())) ?? []
                if let account = all.first(where: { $0.id == accountId }) {
                    _ = try? await api.quickLogin(account: account)
                }
            }

            dismiss()
            onConnected()
        }
    }
}

// MARK: - Conditional View Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self.navigationTitle("切换服务器")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
