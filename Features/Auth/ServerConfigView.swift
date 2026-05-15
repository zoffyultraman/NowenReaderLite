import SwiftUI

struct ServerConfigView: View {
    @State private var serverURL = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: ConnectionStatus = .none
    @State private var showError = false
    @State private var errorMessage = ""

    @ObservedObject private var api = APIClient.shared
    var onConnected: () -> Void

    enum ConnectionStatus {
        case none, testing, success, failure
    }

    var body: some View {
        NavigationStack {
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
                .padding(.bottom, 60)

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
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .alert("连接错误", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var borderColor: Color {
        switch connectionStatus {
        case .success: return .green.opacity(0.5)
        case .failure: return .red.opacity(0.5)
        default: return .gray.opacity(0.3)
        }
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
        api.setServerURL(serverURL)
        onConnected()
    }
}
