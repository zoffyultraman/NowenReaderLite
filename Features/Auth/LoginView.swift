import SwiftUI

struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""

    @ObservedObject private var api = APIClient.shared
    var onLoginSuccess: () -> Void

    @State private var navigateToServerConfig = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // 标题
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)

                    Text(isRegistering ? "创建账号" : "欢迎回来")
                        .font(.title2.weight(.bold))

                    Button {
                        navigateToServerConfig = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                            Text(api.serverURL)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 40)

                // 表单
                VStack(spacing: 14) {
                    // 用户名
                    HStack(spacing: 12) {
                        Image(systemName: "person")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("用户名", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(14)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.gray.opacity(0.2), lineWidth: 1))

                    // 密码
                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        SecureField("密码", text: $password)
                            .textContentType(isRegistering ? .newPassword : .password)
                    }
                    .padding(14)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.gray.opacity(0.2), lineWidth: 1))

                    // 昵称（仅注册时显示）
                    if isRegistering {
                        HStack(spacing: 12) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("昵称", text: $nickname)
                                .textContentType(.name)
                        }
                        .padding(14)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.gray.opacity(0.2), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // 操作按钮
                VStack(spacing: 14) {
                    Button(action: submit) {
                        HStack {
                            if isLoading {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            }
                            Text(isRegistering ? "注册" : "登录")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? Color.accentColor : Color.gray.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSubmit || isLoading)

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isRegistering.toggle()
                        }
                    } label: {
                        Text(isRegistering ? "已有账号？登录" : "没有账号？注册")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }

                    Button {
                        navigateToServerConfig = true
                    } label: {
                        Label("切换服务器", systemImage: "server.rack")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .alert("错误", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .navigationDestination(isPresented: $navigateToServerConfig) {
                ServerListView()
            }
        }
    }

    private var canSubmit: Bool {
        if isRegistering {
            return !username.isEmpty && !password.isEmpty && !nickname.isEmpty
        }
        return !username.isEmpty && !password.isEmpty
    }

    private func submit() {
        isLoading = true
        Task {
            do {
                if isRegistering {
                    _ = try await api.register(username: username, password: password, nickname: nickname)
                } else {
                    _ = try await api.login(username: username, password: password)
                }
                onLoginSuccess()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
        }
    }
}
