import SwiftUI
import SwiftData

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
                NavigationLink {
                    ServerListView()
                } label: {
                    HStack {
                        let isHTTPS = api.serverURL.lowercased().hasPrefix("https://")
                        Image(systemName: isHTTPS ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(isHTTPS ? .green : .red)
                            .font(.caption)
                            .frame(width: 16)
                        Label("服务器", systemImage: "server.rack")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(api.serverURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                NavigationLink {
                    AccountManagerView()
                } label: {
                    HStack {
                        Color.clear
                            .frame(width: 16)
                        Label("账号管理", systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(.primary)
                    }
                }

                if !api.serverURL.isEmpty && !api.serverURL.lowercased().hasPrefix("https://") {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("当前使用 HTTP 明文连接，数据（含密码）可能被截获")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // 关于
            Section("关于") {
                LabeledContent("版本", value: "1.0.1")
                if let url = URL(string: "https://github.com/cropflre/nowen-reader") {
                    Link("项目主页", destination: url)
                }
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