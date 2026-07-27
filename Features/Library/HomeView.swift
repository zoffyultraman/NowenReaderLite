import SwiftUI
import SwiftData

extension Notification.Name {
    static let networkRecovered = Notification.Name("networkRecovered")
}

struct HomeView: View {
    @State private var continueReadingVM = ContinueReadingViewModel()
    @State private var searchVM = SearchViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api
    @FocusState private var isSearchFocused: Bool

    /// 是否处于搜索状态
    private var isSearching: Bool {
        !searchVM.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        @Bindable var searchVM = searchVM
        Group {
            if isSearching {
                HomeSearchResults(
                    searchVM: searchVM,
                    isSearchFocused: $isSearchFocused
                )
            } else {
                HomeMainContent(
                    continueReadingVM: continueReadingVM,
                    searchVM: searchVM,
                    isSearchFocused: $isSearchFocused
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { value in
            if value.hasPrefix("group_") {
                let route = parseGroupRoute(value)
                GroupDetailView(groupId: route.id, contentType: route.contentType)
            } else if let seriesId = Comic.seriesId(from: value) {
                SeriesDetailView(seriesId: seriesId)
            } else {
                ComicDetailView(comicId: value)
            }
        }
        .task(id: HomeRefreshID(
            selectedLibraryId: api.selectedLibraryId,
            isOffline: api.isOfflineMode,
            networkRecovered: api.networkRecovered
        )) {
            continueReadingVM.setModelContext(modelContext)
            await continueReadingVM.load()
        }
        .onChange(of: api.networkRecovered) { _, recovered in
            if recovered {
                NotificationCenter.default.post(name: .networkRecovered, object: nil)
            }
        }
    }
}

private func parseGroupRoute(_ value: String) -> (id: Int, contentType: String?) {
    let parts = value.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
    let id = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let contentType = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
    return (id, contentType)
}

private enum HomeSection: String, CaseIterable {
    case library
    case collections

    var title: String {
        switch self {
        case .library: return "书库"
        case .collections: return "合集"
        }
    }
}

private struct HomeRefreshID: Hashable {
    let selectedLibraryId: String?
    let isOffline: Bool
    let networkRecovered: Bool
}

private struct LibraryContentLoadID: Hashable {
    let selectedLibraryId: String?
    let contentType: String?
    let sortOption: String?
    let isOffline: Bool
    let networkRecovered: Bool
}

// MARK: - 搜索栏

struct HomeSearchBar: View {
    @Bindable var searchVM: SearchViewModel
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索漫画或小说...", text: $searchVM.query)
                .textInputAutocapitalization(.never)
                .focused($isSearchFocused)
                .onSubmit { searchVM.search(immediately: true) }
                .onChange(of: searchVM.query) { _, _ in
                    searchVM.search()
                }
            if !searchVM.query.isEmpty {
                Button {
                    searchVM.clear()
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
}

// MARK: - 书库选择器

struct LibraryPickerView: View {
    @Environment(APIClient.self) private var api

    var body: some View {
        if api.accessibleLibraries.count > 1 {
            Menu {
                Button("全部书库", systemImage: "square.grid.2x2") {
                    api.selectedLibraryId = nil
                }
                ForEach(api.accessibleLibraries.filter { $0.enabled }) { library in
                    Button(library.name, systemImage: api.libraryIcon(for: library.type)) {
                        api.selectedLibraryId = library.id
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: api.selectedLibraryIcon)
                        .foregroundStyle(.secondary)
                    Text(api.selectedLibraryName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}

// MARK: - 搜索结果

struct HomeSearchResults: View {
    @Bindable var searchVM: SearchViewModel
    @FocusState.Binding var isSearchFocused: Bool
    @Environment(APIClient.self) private var api

    var body: some View {
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
                        SearchResultRow(id: comic.id, title: comic.title, author: comic.author, isNovel: comic.isNovel, isFavorite: comic.isFavorite, serverURL: api.serverURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeSearchBar(searchVM: searchVM, isSearchFocused: $isSearchFocused)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }
}

// MARK: - 主内容

struct HomeMainContent: View {
    let continueReadingVM: ContinueReadingViewModel
    @Bindable var searchVM: SearchViewModel
    @FocusState.Binding var isSearchFocused: Bool
    @Environment(APIClient.self) private var api
    @State private var selectedSection: HomeSection = .library

    /// 根据选中的书库类型决定内容筛选
    private var selectedLibraryType: String? {
        guard let selectedId = api.selectedLibraryId,
              let library = api.accessibleLibraries.first(where: { $0.id == selectedId }) else {
            return nil  // "全部" — 不筛选类型
        }
        if library.type == "mixed" { return nil }
        return library.type  // "comic" or "novel"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                HomeSearchBar(searchVM: searchVM, isSearchFocused: $isSearchFocused)
                    .padding(.top, 16)

                LibraryPickerView()

                ContinueReadingSection(
                    items: continueReadingVM.items,
                    errorMessage: continueReadingVM.errorMessage
                )

                Picker("内容", selection: $selectedSection) {
                    ForEach(HomeSection.allCases, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                if selectedSection == .library {
                    LibraryContentView(contentType: selectedLibraryType)
                } else {
                    CollectionContentView(contentType: selectedLibraryType)
                }
            }
            .refreshable {
                await continueReadingVM.load()
            }

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

// MARK: - 继续观看段落

struct ContinueReadingSection: View {
    let items: [Comic]
    let errorMessage: String?
    @Environment(APIClient.self) private var api

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "book.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("继续观看")
                            .font(.title3.weight(.bold))
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(items) { comic in
                                NavigationLink {
                                    comic.readerView()
                                } label: {
                                    ContinueReadingCard(id: comic.id, title: comic.title, progress: comic.progress, serverURL: api.serverURL)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 160)
                }
                .padding(.top, 16)
            }

            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
    }
}

// MARK: - 继续观看卡片（Hero 横向卡片）

struct ContinueReadingCard: View {
    let id: String
    let title: String
    let progress: Int
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .aspectRatio(3/4, contentMode: .fill)
                .frame(width: 90, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // 信息区
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                // 进度信息
                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text("\(progress)% 已读")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.systemGray5))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(progress) / 100)
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, 8)
        } 
        .padding(10)
        .frame(width: 240, height: 140)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - 内容列表（漫画 or 小说）

struct LibraryContentView: View {
    let contentType: String?
    @State private var viewModel = LibraryViewModel()
    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .addedAt
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api

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

    var comics: [Comic] { viewModel.comics }

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "books.vertical")
                    .foregroundStyle(Color.accentColor)
                Text(api.selectedLibraryName)
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Group {
                if comics.isEmpty && !viewModel.isLoading {
                    LibraryEmptyState(contentType: contentType)
                } else if viewMode == .grid {
                    LibraryComicGridView(
                        comics: comics,
                        columns: gridColumns,
                        serverURL: api.serverURL,
                        isLoading: viewModel.isLoading,
                        loadMore: { await viewModel.loadMore() }
                    )
                } else {
                    LibraryComicListView(
                        comics: comics,
                        serverURL: api.serverURL,
                        isLoading: viewModel.isLoading,
                        loadMore: { await viewModel.loadMore() }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if let iconURL = api.siteIconURL {
                        AuthenticatedImage(url: iconURL)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(api.siteName.isEmpty ? (URL(string: api.serverURL)?.host ?? "") : api.siteName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }

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
        .task(id: LibraryContentLoadID(
            selectedLibraryId: api.selectedLibraryId,
            contentType: contentType,
            sortOption: sortOption.rawValue,
            isOffline: api.isOfflineMode,
            networkRecovered: api.networkRecovered
        )) {
            viewModel.setModelContext(modelContext)
            await viewModel.configure(
                contentType: contentType,
                sortBy: sortOption.rawValue,
                sortOrder: sortOption == .title ? "asc" : "desc"
            )
        }
    }

}

private struct LibraryComicGridView: View {
    let comics: [Comic]
    let columns: [GridItem]
    let serverURL: String
    let isLoading: Bool
    let loadMore: () async -> Void

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(comics) { comic in
                NavigationLink(value: comic.id) {
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
                            rating: comic.rating
                        )
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            if !isLoading {
                Color.clear.task { await loadMore() }
            }

            if isLoading {
                ProgressView()
                    .gridCellColumns(columns.count)
                    .padding()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct LibraryComicListView: View {
    let comics: [Comic]
    let serverURL: String
    let isLoading: Bool
    let loadMore: () async -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(comics) { comic in
                VStack {
                    NavigationLink(value: comic.id) {
                        if comic.isSeriesShelfItem {
                            SeriesShelfListRowView(comic: comic, serverURL: serverURL)
                                .padding(.horizontal, 16)
                        } else {
                            ComicListRowView(
                                id: comic.id,
                                title: comic.title,
                                author: comic.author,
                                pageCount: comic.pageCount,
                                fileSize: comic.fileSize,
                                progress: comic.progress,
                                isFavorite: comic.isFavorite,
                                serverURL: serverURL,
                                readingStatus: comic.readingStatus,
                                rating: comic.rating
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    Divider().padding(.leading, 80)
                }
            }

            if !isLoading {
                Color.clear.task { await loadMore() }
            }

            if isLoading {
                ProgressView().padding()
            }
        }
    }
}

private struct LibraryEmptyState: View {
    let contentType: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: contentType == "novel" ? "text.book.closed" : "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(contentType == "novel" ? "还没有小说" : "还没有漫画")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }
}

// MARK: - 合集列表

struct CollectionContentView: View {
    let contentType: String?
    @State private var viewModel = CollectionViewModel()
    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .defaultOrder
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api

    enum ViewMode { case grid, list }
    enum SortOption: String, CaseIterable {
        case defaultOrder, title

        var label: String {
            switch self {
            case .defaultOrder: return "默认排序"
            case .title: return "标题"
            }
        }
    }

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(Color.accentColor)
                Text("合集")
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Group {
                if viewModel.groups.isEmpty && !viewModel.isLoading {
                    CollectionEmptyState()
                } else if viewMode == .grid {
                    CollectionGridView(
                        groups: viewModel.groups,
                        columns: gridColumns,
                        serverURL: api.serverURL,
                        contentType: contentType,
                        isLoading: viewModel.isLoading
                    )
                } else {
                    CollectionListView(
                        groups: viewModel.groups,
                        serverURL: api.serverURL,
                        contentType: contentType,
                        isLoading: viewModel.isLoading
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if let iconURL = api.siteIconURL {
                        AuthenticatedImage(url: iconURL)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(api.siteName.isEmpty ? (URL(string: api.serverURL)?.host ?? "") : api.siteName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }

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
                            viewModel.updateSort(by: option.rawValue, order: "asc")
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
        .task(id: LibraryContentLoadID(
            selectedLibraryId: api.selectedLibraryId,
            contentType: contentType,
            sortOption: nil,
            isOffline: api.isOfflineMode,
            networkRecovered: api.networkRecovered
        )) {
            viewModel.setModelContext(modelContext)
            await viewModel.setContentType(contentType)
        }
    }

}

private struct CollectionGridView: View {
    let groups: [ComicGroup]
    let columns: [GridItem]
    let serverURL: String
    let contentType: String?
    let isLoading: Bool

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(groups) { group in
                NavigationLink(value: navigationValue(for: group)) {
                    GroupCardView(group: group, serverURL: serverURL)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            if isLoading {
                ProgressView()
                    .gridCellColumns(columns.count)
                    .padding()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func navigationValue(for group: ComicGroup) -> String {
        guard let contentType, !contentType.isEmpty else { return "group_\(group.id)" }
        return "group_\(group.id)_\(contentType)"
    }
}

private struct CollectionListView: View {
    let groups: [ComicGroup]
    let serverURL: String
    let contentType: String?
    let isLoading: Bool

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(groups) { group in
                NavigationLink(value: navigationValue(for: group)) {
                    GroupListRowView(group: group, serverURL: serverURL)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                Divider().padding(.leading, 80)
            }

            if isLoading {
                ProgressView().padding()
            }
        }
    }

    private func navigationValue(for group: ComicGroup) -> String {
        guard let contentType, !contentType.isEmpty else { return "group_\(group.id)" }
        return "group_\(group.id)_\(contentType)"
    }
}

private struct CollectionEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("还没有合集")
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
    private let titleAreaHeight: CGFloat = 42

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
                        .aspectRatio(3/4, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray5))
                        .aspectRatio(3/4, contentMode: .fill)
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
                .padding(.top, 8)
                .frame(height: titleAreaHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - 目录作品卡片（网格）

struct SeriesShelfCardView: View {
    let comic: Comic
    let serverURL: String
    private let titleAreaHeight: CGFloat = 42
    private let accessoryAreaHeight: CGFloat = 14

    private var coverImageURL: URL? {
        guard let cover = comic.coverUrl, !cover.isEmpty else { return nil }
        return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let url = coverImageURL {
                        AuthenticatedImage(url: url)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray5))
                            .overlay {
                                Image(systemName: "books.vertical")
                                    .font(.title2)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .aspectRatio(3/4, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.gray.opacity(0.12), lineWidth: 0.5)
                )

                Text("目录")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)

                VStack {
                    Spacer()
                    HStack {
                        if comic.seriesProgress > 0 {
                            Text("\(comic.seriesProgress)%")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(.leading, 6)
                        }
                        Spacer()
                        Text("\(comic.pageCount)项")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.trailing, 8)
                    }

                    if comic.seriesProgress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(.black.opacity(0.25))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(comic.seriesProgress) / 100)
                            }
                        }
                        .frame(height: 3)
                    }
                }

                if comic.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }

            Text(comic.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
                .frame(height: titleAreaHeight, alignment: .topLeading)

            Color.clear
                .frame(height: accessoryAreaHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}


// MARK: - 目录作品行（列表）

struct SeriesShelfListRowView: View {
    let comic: Comic
    let serverURL: String

    private var coverImageURL: URL? {
        guard let cover = comic.coverUrl, !cover.isEmpty else { return nil }
        return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = coverImageURL {
                    AuthenticatedImage(url: url)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .overlay {
                            Image(systemName: "books.vertical")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: 56, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                let sizeText = comic.fileSize.map { formatFileSize($0) } ?? ""
                Text("目录作品 · \(comic.pageCount) 项\(comic.seriesProgress > 0 ? " · \(comic.seriesProgress)% 已读" : "")\(sizeText.isEmpty ? "" : " · \(sizeText)")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if (comic.totalReadTime ?? 0) > 0 {
                    Text(formatDuration(comic.totalReadTime ?? 0))
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
                    .frame(width: 56, height: 75)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 75)
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
@Observable
final class ContinueReadingViewModel {
    var items: [Comic] = []
    var errorMessage: String?

    private var modelContext: ModelContext?
    private var loadVersion = 0

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load() async {
        loadVersion += 1
        let version = loadVersion
        let api = APIClient.shared

        // 离线或网络状态未就绪：直接从缓存加载，等待 networkRecovered 后再刷新线上数据。
        guard !api.isOfflineMode, api.isNetworkReachable else {
            await loadFromCache(version: version)
            return
        }

        do {
            let resp = try await api.fetchComics(
                page: 1,
                pageSize: 20,
                sortBy: "lastReadAt",
                sortOrder: "desc"
            )
            guard !Task.isCancelled, version == loadVersion else { return }
            items = resp.comics.filter { $0.lastReadPage > 0 && $0.progress > 0 && $0.progress < 100 }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled,
                  version == loadVersion else {
                return
            }
            AppLogger.log("加载继续观看失败，使用本地缓存: \(error.localizedDescription)")
            await loadFromCache(version: version)
        }
    }

    /// 离线 fallback：从 SwiftData 缓存 + 本地已下载漫画加载
    private func loadFromCache(version: Int) async {
        let downloadedIds = await Task.detached(priority: .utility) {
            Set(OfflineFileManager.shared.completedDownloads().keys)
        }.value
        guard !Task.isCancelled, version == loadVersion else { return }
        guard let context = modelContext else { return }
        let cached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "离线加载继续观看")

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
