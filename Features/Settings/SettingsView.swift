import SwiftUI
import SwiftData

struct SettingsView: View {
    @ObservedObject private var api = APIClient.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false
    @State private var cacheSize: Int = 0
    @State private var novelCacheSize: Int = 0
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    @AppStorage("keepOriginalSize") private var keepOriginalSize: Bool = false
    @AppStorage("pageTransitionStyle") private var pageTransitionStyle: String = "翻书"

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

            // AI 图像增强
            Section("AI 图像增强") {
                HStack {
                    Label("超分辨率", systemImage: "sparkles")
                    Spacer()
                    Menu {
                        ForEach(UpscaleMode.allCases) { mode in
                            Button(mode.rawValue) {
                                upscaleMode = mode
                            }
                        }
                    } label: {
                        HStack {
                            Text(upscaleMode.rawValue)
                                .foregroundColor(.primary)
                                .animation(nil, value: upscaleMode)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }

                Toggle(isOn: $keepOriginalSize) {
                    Label("保持原尺寸", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .tint(.accentColor)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(keepOriginalSize ?
                         "增强细节但不放大图片，节省内存" :
                         "超分放大图片，可能增加内存占用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 阅读设置
            Section("阅读设置") {
                HStack {
                    Label("翻页效果", systemImage: "book.pages")
                    Spacer()
                    Menu {
                        Button("翻书") { pageTransitionStyle = "翻书" }
                        Button("平移") { pageTransitionStyle = "平移" }
                    } label: {
                        HStack {
                            Text(pageTransitionStyle)
                                .foregroundColor(.primary)
                                .animation(nil, value: pageTransitionStyle)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }

            // 缓存
            Section("缓存") {
                HStack {
                    Label("漫画缓存", systemImage: "internaldrive")
                    Spacer()
                    Text(formatFileSize(Int64(cacheSize)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("小说章节缓存", systemImage: "text.book.closed")
                    Spacer()
                    Text(formatFileSize(Int64(novelCacheSize)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showClearCacheAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Text("清空缓存")
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
                .disabled(cacheSize == 0 && novelCacheSize == 0)
            }

            // 关于
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
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
        .task {
            loadCacheSize()
        }
        .alert("退出登录", isPresented: $showLogoutAlert) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                Task {
                    clearCache()
                    await api.logout()
                }
            }
        } message: {
            Text("确定要退出登录吗？")
        }
        .alert("清空缓存", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clearCache()
            }
        } message: {
            Text("将释放 \(formatFileSize(Int64(cacheSize + novelCacheSize))) 空间，不影响服务器数据。")
        }
    }

    private func loadCacheSize() {
        let comics = modelContext.fetchOrLog(FetchDescriptor<CachedComic>(), label: "加载缓存大小")
        cacheSize = comics.reduce(0) { total, comic in
            total
                + (comic.id.utf8.count)
                + (comic.title.utf8.count)
                + (comic.author?.utf8.count ?? 0)
                + (comic.coverUrl?.utf8.count ?? 0)
                + (comic.type?.utf8.count ?? 0)
                + 8 + 8 + 1 + 8 + 8 + 8 + 8
        }
        novelCacheSize = ChapterCache.totalNovelCacheBytes
        // 图片磁盘缓存计入总大小
        cacheSize += Int(ImageCache.shared.diskSize)
    }

    private func clearCache() {
        try? modelContext.delete(model: CachedComic.self)
        modelContext.saveOrLog()
        cacheSize = 0
        novelCacheSize = 0
        ChapterCache.totalNovelCacheBytes = 0
        NotificationCenter.default.post(name: .novelChapterCacheClear, object: nil)
        ImageCache.shared.clear()
    }
}
