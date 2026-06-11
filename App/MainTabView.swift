import SwiftUI
import SwiftData
import Network

struct MainTabView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0

    var body: some View {
        let api = APIClient.shared
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
        .onAppear {
            downloadManager.setModelContext(modelContext)
            downloadManager.restoreFromStore(context: modelContext)
            // 启动网络恢复监听
            api.startNetworkRecovery()
            // 启动时尝试同步离线进度
            syncPendingProgress()
        }
        .onChange(of: api.networkRecovered) { _, recovered in
            if recovered { syncPendingProgress() }
        }
    }

    /// 联网后同步离线阅读进度到服务端
    private func syncPendingProgress() {
        let api = APIClient.shared
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
}
