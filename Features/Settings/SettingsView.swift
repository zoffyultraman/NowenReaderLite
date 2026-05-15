import SwiftUI

struct SettingsView: View {
    @ObservedObject private var api = APIClient.shared
    @State private var showLogoutAlert = false

    var body: some View {
        List {
            // 用户信息
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(api.currentUser?.nickname ?? api.currentUser?.username ?? "用户")
                            .font(.headline)
                        Text(api.currentUser?.username ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // 服务器
            Section("服务器") {
                LabeledContent("地址", value: api.serverURL)
            }

            // 关于
            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                Link("项目主页", destination: URL(string: "https://github.com/cropflre/nowen-reader")!)
            }

            // 退出
            Section {
                Button(role: .destructive) {
                    showLogoutAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Text("退出登录")
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("设置")
        .alert("退出登录", isPresented: $showLogoutAlert) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                Task { await api.logout() }
            }
        } message: {
            Text("确定要退出登录吗？")
        }
    }
}
