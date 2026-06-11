import SwiftUI
import SwiftData

extension Notification.Name {
    static let networkRecovered = Notification.Name("networkRecovered")
}

struct HomeView: View {
    @State private var selectedTab: ContentType = .comic
    @StateObject private var continueReadingVM = ContinueReadingViewModel()
    @StateObject private var searchVM = SearchViewModel()
    @ObservedObject private var api = APIClient.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isSearchFocused: Bool

    enum ContentType: String, CaseIterable {
        case comic, novel
        var title: String { self == .comic ? "漫画" : "小说" }
        var icon: String { self == .comic ? "photo.stack" : "text.book.closed" }
    }

    /// 是否处于搜索状态
    private var isSearching: Bool {
        !searchVM.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                searchResultsList
            } else {
                mainContent
            }
        }
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { value in
            if value.hasPrefix("group_") {
                let id = Int(value.replacingOccurrences(of: "group_", with: "")) ?? 0
                GroupDetailView(groupId: id)
            } else {
                ComicDetailView(comicId: value)
            }
        }
        .task {
            continueReadingVM.setModelContext(modelContext)
            await continueReadingVM.load()
        }
        .onChange(of: api.isOfflineMode) { _, isOffline in
            if isOffline {
                Task { await continueReadingVM.load() }
            }
        }
        .onReceive(api.$networkRecovered) { recovered in
            if recovered {
                Task {
                    await continueReadingVM.load()
                    // 通知 LibraryContentView 刷新
                    NotificationCenter.default.post(name: .networkRecovered, object: nil)
                    api.networkRecovered = false
                }
            }
        }
    }

    // MARK: - 搜索栏（复用）

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索漫画或小说...", text: $searchVM.query)
                .textInputAutocapitalization(.never)
                .focused($isSearchFocused)
                .onSubmit { searchVM.search() }
                .onChange(of: searchVM.query) { _, _ in
                    searchVM.search()
                }
            if !searchVM.query.isEmpty {
                Button {
                    searchVM.query = ""
                    searchVM.results = []
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // MARK: - 搜索结果

    private var searchResultsList: some View {
        List {
            if searchVM.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if searchVM.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("没有找到结果")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .listRowBackground(Color.clear)
            } else {
                ForEach(searchVM.results) { comic in
                    NavigationLink(value: comic.id) {
                        SearchResultRow(comic: comic)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .top) {
            searchBar.padding(.top, 8)
        }
    }

    // MARK: - 主内容

    private var mainContent: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                searchBar
                    .padding(.top, 8)

                // 继续观看
                if !continueReadingVM.items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("继续观看")
                            .font(.headline)
                            .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(continueReadingVM.items) { comic in
                                    NavigationLink {
                                        comic.readerView()
                                    } label: {
                                        ContinueReadingCard(comic: comic, serverURL: APIClient.shared.serverURL)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .frame(height: sizeClass == .regular ? 260 : 220)
                    }
                    .padding(.top, 8)
                }

                // 加载失败提示
                if let error = continueReadingVM.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }

                // 分类切换
                Picker("类型", selection: $selectedTab) {
                    ForEach(ContentType.allCases, id: \.self) { type in
                        Label(type.title, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, continueReadingVM.items.isEmpty ? 8 : 16)

                // 内容列表
                if selectedTab == .comic {
                    LibraryContentView(contentType: "comic")
                } else {
                    LibraryContentView(contentType: "novel")
                }
            }
            .refreshable {
                await continueReadingVM.load()
            }

            // 离线提示 - 固定在屏幕右下角
            if api.isOfflineMode {
                Button {
                    Task { await api.retryConnection() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 10))
                        Text("离线")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - 继续观看卡片

struct ContinueReadingCard: View {
    let comic: Comic
    let serverURL: String
    @Environment(\.horizontalSizeClass) private var sizeClass

    var cardWidth: CGFloat { sizeClass == .regular ? 160 : 140 }
    var cardHeight: CGFloat { sizeClass == .regular ? 220 : 190 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AuthenticatedImage(serverURL: serverURL, comicId: comic.id, thumbnail: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // 离线标识
                if DownloadManager.shared.isDownloaded(comicId: comic.id) {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .background(Circle().fill(.green).frame(width: 18, height: 18))
                                .padding(6)
                        }
                        Spacer()
                    }
                    .frame(width: cardWidth, height: cardHeight)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text("\(comic.progress)%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
                .frame(width: cardWidth)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                )

                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.3))
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(comic.progress) / 100)
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
            }

            Text(comic.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
                .padding(.top, 6)
        }
    }
}

// MARK: - 统一列表项

enum LibraryItem: Identifiable {
    case comic(Comic)
    case group(ComicGroup)

    var id: String {
        switch self {
        case .comic(let c): return c.id
        case .group(let g): return "group_\(g.id)"
        }
    }
}

// MARK: - 内容列表（漫画 or 小说）

struct LibraryContentView: View {
    let contentType: String
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var api = APIClient.shared
    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .addedAt
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext

    enum ViewMode { case grid, list }
    enum SortOption: String, CaseIterable {
        case addedAt, title, lastReadAt, rating, readTime
        var label: String {
            switch self {
            case .addedAt: return "最近添加"
            case .title: return "标题"
            case .lastReadAt: return "最近阅读"
            case .rating: return "评分"
            case .readTime: return "阅读时间"
            }
        }
    }

    /// 合集和散本混在一起，已分组的漫画不重复显示（缓存在 viewModel.displayItems 中）
    var items: [LibraryItem] { viewModel.displayItems }

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        Group {
            if items.isEmpty && !viewModel.isLoading {
                emptyState
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation { viewMode = viewMode == .grid ? .list : .grid }
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }

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
            await viewModel.loadAll(refresh: true)
        }
        .task {
            viewModel.setModelContext(modelContext)
            viewModel.setContentType(contentType)
            if viewModel.comics.isEmpty && viewModel.groups.isEmpty {
                await viewModel.loadAll()
            }
        }
        .onChange(of: api.isOfflineMode) { _, isOffline in
            // 进入离线模式时重新加载（用已下载内容替换可能过期的缓存）
            if isOffline {
                Task { await viewModel.loadAll(refresh: true) }
            }
        }
        .onReceive(api.$networkRecovered) { recovered in
            if recovered {
                Task { await viewModel.loadAll(refresh: true) }
            }
        }
    }

    // MARK: - Grid

    private var gridView: some View {
        let columns = gridColumns
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                switch item {
                case .comic(let comic):
                    NavigationLink(value: comic.id) {
                        ComicCardView(comic: comic, serverURL: APIClient.shared.serverURL)
                    }
                    .buttonStyle(.plain)
                case .group(let group):
                    NavigationLink(value: "group_\(group.id)") {
                        GroupCardView(group: group, serverURL: APIClient.shared.serverURL)
                    }
                    .buttonStyle(.plain)
                }

                if item.id == items.last?.id, !viewModel.isLoading {
                    Color.clear.onAppear { Task { await viewModel.loadMore() } }
                }
            }

            if viewModel.isLoading {
                ProgressView().gridCellColumns(gridColumns.count).padding()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var listView: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .comic(let comic):
                    NavigationLink(value: comic.id) {
                        ComicListRowView(comic: comic, serverURL: APIClient.shared.serverURL)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    Divider().padding(.leading, 80)
                case .group(let group):
                    NavigationLink(value: "group_\(group.id)") {
                        GroupListRowView(group: group, serverURL: APIClient.shared.serverURL)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    Divider().padding(.leading, 80)
                }

                if item.id == items.last?.id, !viewModel.isLoading {
                    Color.clear.onAppear { Task { await viewModel.loadMore() } }
                }
            }

            if viewModel.isLoading { ProgressView().padding() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: contentType == "comic" ? "photo.stack" : "text.book.closed")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(contentType == "comic" ? "还没有漫画" : "还没有小说")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}

// MARK: - 合集卡片（网格）

struct GroupCardView: View {
    let group: ComicGroup
    let serverURL: String

    private var coverImageURL: URL? {
        if let cover = group.coverUrl, !cover.isEmpty {
            return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
        }
        if let firstId = group.firstComicId {
            return URL(string: "\(serverURL)/api/comics/\(firstId)/thumbnail")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if let url = coverImageURL {
                    AuthenticatedImage(url: url)
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .frame(height: 180)
                        .overlay {
                            Image(systemName: "rectangle.stack")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                }

                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 8))
                    Text("\(group.comicCount ?? 0)卷")
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }

            Text(group.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


// MARK: - 合集行（列表）

struct GroupListRowView: View {
    let group: ComicGroup
    let serverURL: String

    private var coverImageURL: URL? {
        if let cover = group.coverUrl, !cover.isEmpty {
            return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
        }
        if let firstId = group.firstComicId {
            return URL(string: "\(serverURL)/api/comics/\(firstId)/thumbnail")
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if let url = coverImageURL {
                AuthenticatedImage(url: url)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 80)
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.comicCount ?? 0) 卷")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 继续观看 ViewModel

@MainActor
final class ContinueReadingViewModel: ObservableObject {
    @Published var items: [Comic] = []
    @Published var errorMessage: String?

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load() async {
        // 离线模式：直接从缓存加载
        if APIClient.shared.isOfflineMode {
            loadFromCache()
            return
        }
        do {
            let resp = try await APIClient.shared.fetchComics(
                page: 1,
                pageSize: 20,
                sortBy: "lastReadAt",
                sortOrder: "desc"
            )
            items = resp.comics.filter { $0.lastReadPage > 0 && $0.progress > 0 && $0.progress < 100 }
            errorMessage = nil
        } catch {
            AppLogger.log("网络不可用，从本地缓存加载继续观看")
            loadFromCache()
        }
    }

    /// 离线 fallback：从 SwiftData 缓存 + 本地已下载漫画加载
    private func loadFromCache() {
        guard let context = modelContext else { return }
        let cached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "离线加载继续观看")
        let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)

        // 优先显示已下载且有阅读进度的漫画
        let offlineItems = cached
            .filter { downloadedIds.contains($0.id) && $0.lastReadPage > 0 && $0.progress > 0 && $0.progress < 100 }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            .map { $0.toComic() }

        if !offlineItems.isEmpty {
            items = offlineItems
            errorMessage = nil
        } else {
            // 没有已下载的在读漫画，显示所有已下载漫画
            let allDownloaded = cached
                .filter { downloadedIds.contains($0.id) }
                .sorted { ($0.lastReadAt ?? $0.cachedAt) > ($1.lastReadAt ?? $1.cachedAt) }
                .map { $0.toComic() }
            items = allDownloaded
            errorMessage = nil
        }
    }
}
