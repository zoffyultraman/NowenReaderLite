import SwiftUI
import SwiftData

// 注意：此 View 当前未被引用，MainTabView 使用 HomeView 中的 LibraryContentView。
// LibraryViewModel 仍被 LibraryContentView 使用，不可删除。

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .addedAt
    @State private var filterType: FilterType = .all

    enum ViewMode { case grid, list }
    enum SortOption: String, CaseIterable {
        case addedAt = "addedAt"
        case title = "title"
        case lastReadAt = "lastReadAt"
        case rating = "rating"
        case pageCount = "pageCount"

        var label: String {
            switch self {
            case .addedAt: return "最近添加"
            case .title: return "标题"
            case .lastReadAt: return "最近阅读"
            case .rating: return "评分"
            case .pageCount: return "页数"
            }
        }
    }

    enum FilterType: String, CaseIterable {
        case all, comic, novel
        var label: String {
            switch self {
            case .all: return "全部"
            case .comic: return "漫画"
            case .novel: return "小说"
            }
        }
    }

    var body: some View {
        Group {
            if viewModel.comics.isEmpty && !viewModel.isLoading {
                emptyState
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .navigationTitle("书架")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 视图切换
                Button {
                    withAnimation { viewMode = viewMode == .grid ? .list : .grid }
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }

                // 类型筛选
                Menu {
                    ForEach(FilterType.allCases, id: \.self) { type in
                        Button {
                            filterType = type
                            viewModel.setContentType(type == .all ? nil : type.rawValue)
                        } label: {
                            HStack {
                                Text(type.label)
                                if filterType == type { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }

                // 排序
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            sortOption = option
                            viewModel.updateSort(by: option.rawValue, order: option == .title ? "asc" : "desc")
                        } label: {
                            HStack {
                                Text(option.label)
                                if sortOption == option { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .refreshable {
            await viewModel.loadComics(refresh: true)
        }
        .task {
            viewModel.setModelContext(modelContext)
            if viewModel.comics.isEmpty {
                await viewModel.loadComics()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.comics.isEmpty {
                ProgressView()
                    .scaleEffect(1.2)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 16)
                    .onTapGesture { viewModel.errorMessage = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: error)
            }
        }
    }

    // MARK: - Grid View

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 16) {
                ForEach(viewModel.comics) { comic in
                    NavigationLink(value: comic.id) {
                        ComicCardView(comic: comic, serverURL: api.serverURL)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if comic.id == viewModel.comics.last?.id {
                            Task { await viewModel.loadMore() }
                        }
                    }
                }

                if viewModel.isLoading {
                    ProgressView()
                        .gridCellColumns(3)
                        .padding()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationDestination(for: String.self) { comicId in
            ComicDetailView(comicId: comicId)
        }
    }

    // MARK: - List View

    private var listView: some View {
        List(viewModel.comics) { comic in
            NavigationLink(value: comic.id) {
                ComicListRowView(comic: comic, serverURL: api.serverURL)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onAppear {
                if comic.id == viewModel.comics.last?.id {
                    Task { await viewModel.loadMore() }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: String.self) { comicId in
            ComicDetailView(comicId: comicId)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("书库空空如也")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("添加一些漫画或小说开始阅读吧")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var api: APIClient { .shared }
}

// MARK: - 漫画卡片

struct ComicCardView: View {
    let comic: Comic
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 封面
            ZStack(alignment: .topTrailing) {
                AuthenticatedImage(serverURL: serverURL, comicId: comic.id, thumbnail: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.15), lineWidth: 0.5)
                    )

                // 收藏标记
                if comic.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }

                // 小说标记
                if comic.isNovel {
                    Text("小说")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // 进度条
                if comic.progress > 0 {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(.black.opacity(0.3))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(comic.progress) / 100)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
            }

            // 标题
            Text(comic.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
        }
    }

}

// MARK: - 列表行

struct ComicListRowView: View {
    let comic: Comic
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: comic.id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let author = comic.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if comic.pageCount > 0 {
                    let sizeText = comic.fileSize.map { formatFileSize($0) } ?? ""
                    Text("\(comic.pageCount) 页 · \(comic.progress)% 已读\(sizeText.isEmpty ? "" : " · \(sizeText)")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if comic.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

}

// MARK: - ViewModel

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var comics: [Comic] = []
    @Published var groups: [ComicGroup] = []
    @Published var groupedComicIds: Set<String> = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?
    @Published var displayItems: [LibraryItem] = []

    private var currentPage = 1
    private var sortBy = "addedAt"
    private var sortOrder = "desc"
    private var contentType: String?
    private let api = APIClient.shared
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 同时加载合集、漫画列表和分组映射
    func loadAll(refresh: Bool = false) async {
        isLoading = true
        async let g: () = loadGroups()
        async let c: () = loadComics(refresh: refresh)
        async let m: () = loadGroupMap()
        _ = await (g, c, m)
        isLoading = false
        updateDisplayItems()
    }

    func updateDisplayItems() {
        if contentType == "comic" {
            var result: [LibraryItem] = groups.map { .group($0) }
            let ungrouped = comics.filter { !groupedComicIds.contains($0.id) }
            result.append(contentsOf: ungrouped.map { .comic($0) })
            displayItems = result
        } else {
            displayItems = comics.map { .comic($0) }
        }
    }

    func loadComics(refresh: Bool = false) async {
        if refresh { currentPage = 1 }

        // 首次加载时先显示缓存数据
        if currentPage == 1, let context = modelContext {
            let cached = loadFromCache(context: context)
            if !cached.isEmpty && comics.isEmpty {
                comics = cached
            }
        }

        do {
            let resp = try await api.fetchComics(
                page: currentPage,
                sortBy: sortBy,
                sortOrder: sortOrder,
                contentType: contentType
            )
            if refresh || currentPage == 1 {
                comics = resp.comics
            } else {
                comics.append(contentsOf: resp.comics)
            }
            hasMore = currentPage < resp.totalPages

            // 更新缓存
            if let context = modelContext, (refresh || currentPage == 1) {
                saveToCache(resp.comics, context: context)
            }
        } catch {
            AppLogger.error("加载漫画失败: \(error)")
            errorMessage = error.localizedDescription
            // API 失败时如果有缓存数据则保留，不显示空状态
            if comics.isEmpty, let context = modelContext {
                comics = loadFromCache(context: context)
            }
        }
    }

    private func loadFromCache(context: ModelContext) -> [Comic] {
        let descriptor = FetchDescriptor<CachedComic>(
            sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)]
        )
        guard let cached = try? context.fetch(descriptor) else { return [] }
        return cached.map { $0.toComic() }
    }

    private func saveToCache(_ comics: [Comic], context: ModelContext) {
        for comic in comics {
            let id = comic.id
            let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
            if let existing = try? context.fetch(descriptor), let first = existing.first {
                // 更新已有记录
                first.title = comic.title
                first.author = comic.author
                first.coverUrl = comic.coverUrl
                first.pageCount = comic.pageCount
                first.lastReadPage = comic.lastReadPage
                first.isFavorite = comic.isFavorite
                first.rating = comic.rating
                first.type = comic.type
                first.progress = comic.progress
                first.lastReadAt = comic.lastReadAt.flatMap { Date.fromISO8601($0) }
                first.cachedAt = Date()
            } else {
                // 插入新记录
                context.insert(CachedComic.from(comic))
            }
        }
        context.saveOrLog()
    }

    func loadGroups() async {
        guard contentType == "comic" else {
            groups = []
            return
        }
        do {
            groups = try await api.fetchGroups(contentType: contentType)
        } catch {
            AppLogger.error("加载合集失败: \(error)")
        }
    }

    func loadGroupMap() async {
        guard contentType == "comic" else {
            groupedComicIds = []
            return
        }
        do {
            groupedComicIds = try await api.fetchComicGroupMap()
        } catch {
            AppLogger.error("加载分组映射失败: \(error)")
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        currentPage += 1
        await loadComics()
        updateDisplayItems()
    }

    func updateSort(by: String, order: String) {
        sortBy = by
        sortOrder = order
        Task { await loadComics(refresh: true) }
    }

    func setContentType(_ type: String?) {
        contentType = type
        Task { await loadAll(refresh: true) }
    }
}

