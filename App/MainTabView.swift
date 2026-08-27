import SwiftUI
import SwiftData
import Network

struct MainTabView: View {
    private let downloadManager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(APIClient.self) private var api
    @State private var selectedTab = 0
    @State private var pendingProgressSyncTask: Task<Void, Never>?

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
        .tint(.accentColor)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            downloadManager.setModelContext(modelContext)
            api.startNetworkRecovery()
            syncOfflineReadingState()
        }
        .task {
            downloadManager.setModelContext(modelContext)
            await downloadManager.restoreFromStore(context: modelContext)
            _ = try? await api.fetchAccessibleLibraries()
        }
        .onChange(of: api.networkRecovered) { _, recovered in
            if recovered {
                syncOfflineReadingState()
                Task { _ = try? await api.fetchAccessibleLibraries() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await api.reevaluateAutomaticRoute() }
        }
        .onDisappear {
            pendingProgressSyncTask?.cancel()
            pendingProgressSyncTask = nil
        }
    }

    private func syncOfflineReadingState() {
        syncPendingReadingActivities()
        syncPendingProgress()
    }

    /// 联网后同步离线阅读活动到服务端
    private func syncPendingReadingActivities() {
        let api = APIClient.shared
        guard !api.isOfflineMode, api.isNetworkReachable, PendingReadingActivityManager.shared.hasPending else { return }
        Task { await api.syncPendingReadingActivities() }
    }

    /// 联网后同步离线阅读进度到服务端
    private func syncPendingProgress() {
        let api = APIClient.shared
        let manager = PendingProgressManager.shared
        guard pendingProgressSyncTask == nil,
              !api.isOfflineMode,
              api.isNetworkReachable,
              manager.hasPending else { return }

        pendingProgressSyncTask = Task {
            defer { pendingProgressSyncTask = nil }
            let pending = manager.loadAll().sorted {
                $0.value.updatedAt < $1.value.updatedAt
            }
            AppLogger.log("同步离线进度: \(pending.count) 本漫画")

            for (comicId, record) in pending {
                guard !Task.isCancelled,
                      !api.isOfflineMode,
                      api.isNetworkReachable else { return }
                do {
                    try await api.updateProgress(comicId: comicId, page: record.page, totalPages: record.totalPages)
                    manager.remove(
                        comicId: comicId,
                        ifUnchangedSince: record.updatedAt
                    )
                    AppLogger.log("离线进度已同步: \(comicId) page=\(record.page)")
                } catch {
                    AppLogger.log("离线进度同步失败: \(comicId) \(error.localizedDescription)")
                }
            }
        }
    }
}
