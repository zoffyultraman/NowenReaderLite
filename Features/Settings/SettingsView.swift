import SwiftUI
import SwiftData

struct SettingsView: View {
    private let downloadManager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api
    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false
    @State private var coverCacheSize: Int = 0
    @State private var metaCacheSize: Int = 0
    @State private var novelCacheSize: Int = 0
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    @AppStorage("keepOriginalSize") private var keepOriginalSize: Bool = false
    @AppStorage("offlineStorageLimitMB") private var storageLimitMB: Int = 0  // 0 = 无限制

    var body: some View {
        List {
            UserProfileSettingsSection(
                displayName: api.currentUser?.nickname ?? api.currentUser?.username ?? "用户",
                username: api.currentUser?.username ?? ""
            )
            ServerSettingsSection(
                primaryURL: api.primaryServerURL,
                activeURL: api.serverURL,
                activeRouteTitle: api.backupServerURL == nil ? nil : api.activeRouteTitle,
                usesAPIKey: api.hasConfiguredAPIKey
            )
            if !api.primaryServerURL.isEmpty {
                ServerRouteLatencySettingsSection()
            }
            ImageEnhancementSettingsSection(
                upscaleMode: $upscaleMode,
                keepOriginalSize: $keepOriginalSize
            )
            CacheSettingsSection(
                coverCacheSize: coverCacheSize,
                metaCacheSize: metaCacheSize,
                novelCacheSize: novelCacheSize,
                onClear: { showClearCacheAlert = true }
            )
            OfflineDownloadsSettingsSection(
                offlineSize: downloadManager.usedStorageBytes,
                storageLimitMB: $storageLimitMB
            )
            AboutSettingsSection()
            LogoutSettingsSection {
                showLogoutAlert = true
            }
        }
        .navigationTitle("设置")
        .task {
            await loadCacheSize()
        }
        .alert("退出登录", isPresented: $showLogoutAlert) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                Task {
                    clearCache()
                    await APIClient.shared.logout()
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
            Text("将释放 \(formatFileSize(Int64(coverCacheSize + metaCacheSize + novelCacheSize))) 空间，不影响服务器数据。")
        }
    }

    @MainActor
    private func loadCacheSize() async {
        let cachedComics = modelContext.fetchOrLog(
            FetchDescriptor<CachedComic>(),
            label: "统计元数据缓存"
        )
        let metaBytes = cachedComics.reduce(0) { total, comic in
            total
                + (comic.id.utf8.count)
                + (comic.title.utf8.count)
                + (comic.author?.utf8.count ?? 0)
                + (comic.coverUrl?.utf8.count ?? 0)
                + (comic.type?.utf8.count ?? 0)
                + 8 + 8 + 1 + 8 + 8 + 8 + 8
        }
        let novelBytes = ChapterCache.totalNovelCacheBytes
        async let coverBytes = ImageCache.shared.diskSize()
        async let storageRefresh: Void = downloadManager.refreshStorageUsage()

        metaCacheSize = metaBytes
        coverCacheSize = Int(await coverBytes)
        novelCacheSize = novelBytes
        await storageRefresh
    }

    private func clearCache() {
        try? modelContext.delete(model: CachedComic.self)
        modelContext.saveOrLog()
        metaCacheSize = 0
        coverCacheSize = 0
        Task {
            await ImageCache.shared.clear()
        }
        novelCacheSize = 0
        ChapterCache.totalNovelCacheBytes = 0
        NotificationCenter.default.post(name: .novelChapterCacheClear, object: nil)
    }
}

private struct UserProfileSettingsSection: View {
    let displayName: String
    let username: String

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.headline)
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ServerSettingsSection: View {
    let primaryURL: String
    let activeURL: String
    let activeRouteTitle: String?
    let usesAPIKey: Bool

    var body: some View {
        Section("服务器") {
            NavigationLink {
                ServerListView()
            } label: {
                HStack {
                    let isHTTPS = activeURL.lowercased().hasPrefix("https://")
                    Image(systemName: isHTTPS ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(isHTTPS ? .green : .red)
                        .font(.caption)
                        .frame(width: 16)
                    Label("服务器", systemImage: "server.rack")
                        .foregroundStyle(.primary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(primaryURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let activeRouteTitle {
                            Text(activeRouteTitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if usesAPIKey {
                            Text("API Key")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Cookie")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            NavigationLink {
                AccountManagerView()
            } label: {
                HStack {
                    Color.clear.frame(width: 16)
                    Label("账号管理", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(.primary)
                }
            }

            if !activeURL.isEmpty && !activeURL.lowercased().hasPrefix("https://") {
                Label {
                    Text("当前使用 HTTP 明文连接，数据（含密码）可能被截获")
                        .font(.caption2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }
        }
    }
}

private struct ServerRouteLatencySettingsSection: View {
    @Environment(APIClient.self) private var api

    var body: some View {
        Section {
            ServerRouteInfoRow(title: "线路模式") {
                if api.routeMode == .automatic {
                    Text("自动 · 低延迟优先")
                } else {
                    Text(api.routeMode.title)
                }
            }

            ServerRouteLatencyRow(
                title: "主线路", url: api.primaryServerURL,
                isActive: api.serverURL == api.primaryServerURL,
                latency: api.routeLatencies[api.primaryServerURL],
                isMeasuring: api.isMeasuringRouteLatencies
            )
            if let backupURL = api.backupServerURL {
                ServerRouteLatencyRow(
                    title: "备用线路", url: backupURL,
                    isActive: api.serverURL == backupURL,
                    latency: api.routeLatencies[backupURL],
                    isMeasuring: api.isMeasuringRouteLatencies
                )
                ServerRouteInfoRow(title: "线路验证") {
                    ServerRouteVerificationStatusView(verification: api.routeVerification)
                }
            }

            if let measuredAt = api.routeLatenciesMeasuredAt {
                ServerRouteInfoRow(title: "最近检测") {
                    Text(measuredAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                Task { await api.refreshRouteLatencies() }
            } label: {
                HStack {
                    Label("重新测速", systemImage: "arrow.clockwise")
                    Spacer()
                    if api.isMeasuringRouteLatencies {
                        ProgressView().controlSize(.small)
                    }
                }
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(api.isMeasuringRouteLatencies)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } header: {
            Text("线路延迟")
        } footer: {
            Text("自动模式在前台每 30 秒检测一次，优先使用响应更快的线路；延迟接近时保持当前连接。手动模式只测速。响应延迟不代表下载速度。")
        }
        .task {
            await api.refreshRouteLatencies()
        }
    }
}

private struct ServerRouteInfoRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            content()
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.trailing)
        }
        // 与连接设置保持一致：行高跟随内容，不让自动标签样式撑高列表行。
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

private struct ServerRouteLatencyRow: View {
    let title: LocalizedStringKey
    let url: String
    let isActive: Bool
    let latency: ServerRouteLatency?
    let isMeasuring: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                    if ServerRouteSelector.isLocalURL(url) {
                        Text("内网").font(.caption).foregroundStyle(.secondary)
                    }
                    if isActive {
                        Label("使用中", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let milliseconds = latency?.milliseconds {
                Text("\(max(1, Int(milliseconds.rounded(.up)))) ms")
                    .monospacedDigit()
                    .accessibilityLabel("响应延迟 \(max(1, Int(milliseconds.rounded(.up)))) 毫秒")
            } else if isMeasuring {
                Text("测速中…").foregroundStyle(.secondary)
            } else if latency == .unreachable {
                Text("不可达").foregroundStyle(.orange)
            } else {
                Text("未测速").foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .accessibilityElement(children: .combine)
    }
}

private struct ImageEnhancementSettingsSection: View {
    @Binding var upscaleMode: UpscaleMode
    @Binding var keepOriginalSize: Bool

    var body: some View {
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
                    SettingsMenuLabel(title: upscaleMode.rawValue)
                        .animation(nil, value: upscaleMode)
                }
            }

            Toggle(isOn: $keepOriginalSize) {
                Label("保持原尺寸", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .tint(.accentColor)

            Label {
                Text(keepOriginalSize ? "增强细节但不放大图片，节省内存" : "超分放大图片，可能增加内存占用")
                    .font(.caption2)
            } icon: {
                Image(systemName: "info.circle")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct CacheSettingsSection: View {
    let coverCacheSize: Int
    let metaCacheSize: Int
    let novelCacheSize: Int
    let onClear: () -> Void

    var body: some View {
        Section("缓存") {
            CacheSizeRow(title: "封面缓存", systemImage: "photo", bytes: coverCacheSize)
            CacheSizeRow(title: "元数据缓存", systemImage: "doc.text", bytes: metaCacheSize)
            CacheSizeRow(title: "小说章节缓存", systemImage: "text.book.closed", bytes: novelCacheSize)

            Button(role: .destructive, action: onClear) {
                Text("清空缓存")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .disabled(coverCacheSize == 0 && metaCacheSize == 0 && novelCacheSize == 0)
        }
    }
}

private struct CacheSizeRow: View {
    let title: String
    let systemImage: String
    let bytes: Int

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(formatFileSize(Int64(bytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OfflineDownloadsSettingsSection: View {
    @Binding var storageLimitMB: Int
    let offlineSize: Int64

    private static let limitOptions: [(label: String, value: Int)] = [
        ("无限制", 0), ("1 GB", 1024), ("2 GB", 2048),
        ("4 GB", 4096), ("8 GB", 8192), ("16 GB", 16384),
    ]

    init(offlineSize: Int64, storageLimitMB: Binding<Int>) {
        self.offlineSize = offlineSize
        _storageLimitMB = storageLimitMB
    }

    private var storageRatio: Double {
        let limit = Int64(storageLimitMB) * 1024 * 1024
        guard limit > 0 else { return 0 }
        return Double(offlineSize) / Double(limit)
    }

    private var currentLimitLabel: String {
        Self.limitOptions.first { $0.value == storageLimitMB }?.label ?? "无限制"
    }

    var body: some View {
        Section("已下载漫画") {
            NavigationLink {
                DownloadListView()
            } label: {
                HStack {
                    Label("管理已下载", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(formatFileSize(offlineSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if storageLimitMB > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("已用")
                        Spacer()
                        Text("\(formatFileSize(offlineSize)) / \(formatFileSize(Int64(storageLimitMB) * 1024 * 1024))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemGray5))
                            Capsule()
                                .fill(storageRatio > 0.9 ? Color.red : Color.accentColor)
                                .frame(width: geometry.size.width * CGFloat(min(storageRatio, 1)))
                        }
                    }
                    .frame(height: 6)
                }
            }

            HStack {
                Label("存储上限", systemImage: "internaldrive")
                Spacer()
                Menu {
                    ForEach(Self.limitOptions, id: \.value) { option in
                        Button(option.label) {
                            storageLimitMB = option.value
                        }
                    }
                } label: {
                    SettingsMenuLabel(title: currentLimitLabel)
                        .animation(nil, value: storageLimitMB)
                }
            }

            if storageLimitMB > 0 {
                Label {
                    Text("达到上限后自动暂停新下载，可随时调整")
                        .font(.caption2)
                } icon: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsMenuLabel: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AboutSettingsSection: View {
    var body: some View {
        Section("关于") {
            LabeledContent(
                "版本",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
            )
            if let url = URL(string: "https://github.com/cropflre/nowen-reader") {
                Link("项目主页", destination: url)
            }
        }
    }
}

private struct LogoutSettingsSection: View {
    let action: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive, action: action) {
                Text("退出登录")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
