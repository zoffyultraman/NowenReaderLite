import SwiftUI

struct FavoritesView: View {
    @State private var viewModel = FavoritesViewModel()
    @Environment(APIClient.self) private var api

    var body: some View {
        if api.isOfflineMode {
            OfflineUnavailableView(
                icon: "wifi.slash",
                title: "离线模式不可用",
                subtitle: "收藏功能需要连接服务器"
            )
        } else {
            FavoritesMainContent(viewModel: viewModel)
        }
    }
}

// MARK: - 收藏主内容

struct FavoritesMainContent: View {
    let viewModel: FavoritesViewModel
    @Environment(APIClient.self) private var api

    var body: some View {
        Group {
            if viewModel.entries.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "heart",
                    description: Text("在作品、合集或目录作品详情页点击心形即可加入收藏")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 16) {
                        ForEach(viewModel.entries) { entry in
                            FavoritesGridCell(entry: entry, serverURL: api.serverURL)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .refreshable {
                    await viewModel.loadFavorites()
                }
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.large)
        .comicDetailNavigation()
        .navigationDestination(for: FavoritesGroupRoute.self) { route in
            GroupDetailView(groupId: route.id, contentType: route.contentType)
        }
        .navigationDestination(for: String.self) { comicId in
            ComicDetailView(comicId: comicId)
                .bookCoverDestination(id: "comic-\(comicId)")
        }
        .task(id: FavoritesRefreshID(
            selectedLibraryId: api.selectedLibraryId,
            contentMutationRevision: api.contentMutationRevision,
            networkRecovered: api.networkRecovered
        )) {
            await viewModel.loadFavorites()
        }
        .overlay {
            if viewModel.isLoading && viewModel.entries.isEmpty {
                ProgressView()
            }
        }
    }
}

private struct FavoritesGroupRoute: Hashable {
    let id: Int
    let contentType: String?
}

private struct FavoritesGridCell: View {
    let entry: FavoritesEntry
    let serverURL: String

    var body: some View {
        switch entry {
        case .group(let group):
            NavigationLink(value: FavoritesGroupRoute(id: group.id, contentType: group.contentType)) {
                GroupCardView(group: group, serverURL: serverURL)
            }
            .buttonStyle(.plain)
        case .comic(let comic):
            NavigationLink(value: ComicDetailRoute(comic: comic)) {
                if comic.isSeriesShelfItem {
                    SeriesShelfCardView(comic: comic, serverURL: serverURL)
                } else {
                    ComicCardView(
                        id: comic.id,
                        title: comic.title,
                        isFavorite: comic.isFavorite,
                        isNovel: comic.isNovel,
                        progress: comic.progress,
                        serverURL: serverURL,
                        readingStatus: comic.readingStatus,
                        rating: comic.rating,
                        formatBadge: comic.formatBadge
                    )
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct FavoritesRefreshID: Hashable {
    let selectedLibraryId: String?
    let contentMutationRevision: Int
    let networkRecovered: Bool
}

enum FavoritesEntry: Identifiable, Equatable {
    case group(ComicGroup)
    case comic(Comic)

    var id: String {
        switch self {
        case .group(let group): return "group-\(group.id)"
        case .comic(let comic): return "comic-\(comic.id)"
        }
    }
}

// MARK: - 离线不可用视图（复用）

struct OfflineUnavailableView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
@Observable
final class FavoritesViewModel {
    var entries: [FavoritesEntry] = []
    var isLoading = false
    private var loadVersion = 0

    func loadFavorites() async {
        loadVersion += 1
        let version = loadVersion
        // 离线或网络不可达：立即返回，不挂起等超时
        guard !APIClient.shared.isOfflineMode, APIClient.shared.isNetworkReachable else {
            entries = []
            isLoading = false
            return
        }
        isLoading = true
        defer {
            if version == loadVersion {
                isLoading = false
            }
        }
        do {
            async let favComicsTask = APIClient.shared.fetchComics(
                page: 1,
                pageSize: 0,
                favorites: true,
                excludeGrouped: true,
                seriesView: true
            )
            async let favComicGroupsTask = APIClient.shared.fetchGroups(
                contentType: "comic",
                favoritesOnly: true
            )
            async let favNovelGroupsTask = APIClient.shared.fetchGroups(
                contentType: "novel",
                favoritesOnly: true
            )

            let resp = try await favComicsTask
            let comicGroups = (try? await favComicGroupsTask) ?? []
            let novelGroups = (try? await favNovelGroupsTask) ?? []
            guard !Task.isCancelled, version == loadVersion else { return }

            var seenGroupIds = Set<Int>()
            let mergedGroups = (comicGroups + novelGroups).filter {
                seenGroupIds.insert($0.id).inserted
            }

            let groupedSeriesIds = await loadGroupedSeriesIds(for: mergedGroups)
            guard !Task.isCancelled, version == loadVersion else { return }

            let filteredComics = resp.comics.filter { comic in
                guard let seriesId = comic.seriesId else { return true }
                return !groupedSeriesIds.contains(seriesId)
            }

            entries = mergedGroups.map(FavoritesEntry.group)
                + filteredComics.map(FavoritesEntry.comic)
        } catch {
            guard !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled,
                  version == loadVersion else {
                return
            }
            AppLogger.error("加载收藏失败: \(error)")
            if APIClient.shared.isOfflineMode { entries = [] }
        }
    }

    private func loadGroupedSeriesIds(for groups: [ComicGroup]) async -> Set<String> {
        guard !groups.isEmpty else { return [] }
        let maxConcurrent = 4
        return await withTaskGroup(of: Set<String>.self) { taskGroup in
            var nextIndex = 0
            let initialCount = min(maxConcurrent, groups.count)
            while nextIndex < initialCount {
                let group = groups[nextIndex]
                nextIndex += 1
                taskGroup.addTask {
                    guard let detail = try? await APIClient.shared.fetchGroupDetail(
                        id: group.id,
                        contentType: group.contentType
                    ) else {
                        return []
                    }
                    return Set(detail.seriesList.map(\.id))
                }
            }
            var result = Set<String>()
            for await ids in taskGroup {
                result.formUnion(ids)
                if nextIndex < groups.count && !Task.isCancelled {
                    let group = groups[nextIndex]
                    nextIndex += 1
                    taskGroup.addTask {
                        guard let detail = try? await APIClient.shared.fetchGroupDetail(
                            id: group.id,
                            contentType: group.contentType
                        ) else {
                            return []
                        }
                        return Set(detail.seriesList.map(\.id))
                    }
                }
            }
            return result
        }
    }
}
