import SwiftUI
import SwiftData
import Network

struct MainTabView: View {
    @ObservedObject private var api = APIClient.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("书架", systemImage: "books.vertical.fill")
            }
            .tag(0)

            NavigationStack {
                FavoritesView()
            }
            .tabItem {
                Label("收藏", systemImage: "heart.fill")
            }
            .tag(1)

            NavigationStack {
                StatsView()
            }
            .tabItem {
                Label("统计", systemImage: "chart.bar.fill")
            }
            .tag(2)

            NavigationStack {
                DownloadListView()
            }
            .tabItem {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
            .badge(downloadManager.activeDownloadCount)
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(4)
        }
        .tint(Color.accentColor)
        .safeAreaInset(edge: .top, spacing: 0) {
            if downloadManager.activeDownloadCount > 0 {
                downloadProgressOverlay
            } else {
                EmptyView()
            }
        }
        .onAppear {
            downloadManager.setModelContext(modelContext)
            downloadManager.restoreFromStore(context: modelContext)
            // 启动网络恢复监听
            api.startNetworkRecovery()
            // 启动时尝试同步离线进度
            syncPendingProgress()
        }
    }

    /// 联网后同步离线阅读进度到服务端
    private func syncPendingProgress() {
        guard !api.isOfflineMode, PendingProgressManager.shared.hasPending else { return }
        let pending = PendingProgressManager.shared.loadAll()
        AppLogger.log("同步离线进度: \(pending.count) 本漫画")
        for (comicId, record) in pending {
            Task {
                do {
                    try await api.updateProgress(comicId: comicId, page: record.page)
                    PendingProgressManager.shared.remove(comicId: comicId)
                    AppLogger.log("离线进度已同步: \(comicId) page=\(record.page)")
                } catch {
                    AppLogger.log("离线进度同步失败: \(comicId) \(error.localizedDescription)")
                }
            }
        }
    }

    private var downloadProgressOverlay: some View {
        VStack(spacing: 0) {
            // 状态信息
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(downloadProgressText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(downloadManager.globalProgress * 100))%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray5))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(downloadManager.globalProgress))
                        .animation(.linear(duration: 0.3), value: downloadManager.globalProgress)
                }
            }
            .frame(height: 2)
        }
        .onTapGesture {
            selectedTab = 3  // 跳转到下载页
        }
    }

    private var downloadProgressText: String {
        let count = downloadManager.activeDownloadCount
        if count == 1 {
            // 找到正在下载的任务名
            if let task = downloadManager.tasks.values.first(where: { $0.state == .downloading }) {
                return "正在下载 \(task.title)"
            }
        }
        return "正在下载 \(count) 本漫画"
    }
}
