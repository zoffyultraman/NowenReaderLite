import SwiftUI

struct HomeView: View {
    @State private var selectedTab: ContentType = .comic
    @StateObject private var continueReadingVM = ContinueReadingViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum ContentType: String, CaseIterable {
        case comic, novel
        var title: String { self == .comic ? "漫画" : "小说" }
        var icon: String { self == .comic ? "photo.stack" : "text.book.closed" }
    }

    var body: some View {
        ScrollView {
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
                                    readerView(for: comic)
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
            await continueReadingVM.load()
        }
        .onAppear {
            Task { await continueReadingVM.load() }
        }
        .refreshable {
            await continueReadingVM.load()
        }
    }

    @ViewBuilder
    private func readerView(for comic: Comic) -> some View {
        if comic.isNovel {
            NovelReaderView(comicId: comic.id, initialChapter: comic.lastReadPage)
        } else {
            ComicReaderView(comicId: comic.id, initialPage: comic.lastReadPage)
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
    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .addedAt
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum ViewMode { case grid, list }
    enum SortOption: String, CaseIterable {
        case addedAt, title, lastReadAt, rating, pageCount
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

    /// 合集和散本混在一起，已分组的漫画不重复显示
    var items: [LibraryItem] {
        if contentType == "comic" {
            var result: [LibraryItem] = viewModel.groups.map { .group($0) }
            let ungrouped = viewModel.comics.filter { !viewModel.groupedComicIds.contains($0.id) }
            result.append(contentsOf: ungrouped.map { .comic($0) })
            return result
        }
        return viewModel.comics.map { .comic($0) }
    }

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
            viewModel.setContentType(contentType)
            if viewModel.comics.isEmpty && viewModel.groups.isEmpty {
                await viewModel.loadAll()
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
                    .onAppear {
                        if comic.id == viewModel.comics.last?.id {
                            Task { await viewModel.loadMore() }
                        }
                    }
                case .group(let group):
                    NavigationLink(value: "group_\(group.id)") {
                        GroupCardView(group: group, serverURL: APIClient.shared.serverURL)
                    }
                    .buttonStyle(.plain)
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
                    .onAppear {
                        if comic.id == viewModel.comics.last?.id {
                            Task { await viewModel.loadMore() }
                        }
                    }
                    Divider().padding(.leading, 80)
                case .group(let group):
                    NavigationLink(value: "group_\(group.id)") {
                        GroupListRowView(group: group, serverURL: APIClient.shared.serverURL)
                            .padding(.horizontal, 20)
                    }
                    Divider().padding(.leading, 80)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if let cover = group.coverUrl, !cover.isEmpty {
                    AuthenticatedImage(url: URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)"))
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray6))
                        .frame(height: 180)
                        .overlay(
                            Image(systemName: "rectangle.stack.fill")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                        )
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
                .lineLimit(2)
                .padding(.top, 8)
        }
    }
}

// MARK: - 合集行（列表）

struct GroupListRowView: View {
    let group: ComicGroup
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            if let cover = group.coverUrl, !cover.isEmpty {
                AuthenticatedImage(url: URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)"))
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .frame(width: 56, height: 80)
                    .overlay(Image(systemName: "rectangle.stack.fill").foregroundStyle(.tertiary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.subheadline.weight(.medium))
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

    func load() async {
        do {
            let resp = try await APIClient.shared.fetchComics(
                page: 1,
                pageSize: 20,
                sortBy: "lastReadAt",
                sortOrder: "desc"
            )
            items = resp.comics.filter { $0.lastReadPage > 0 && $0.progress > 0 && $0.progress < 100 }
        } catch {
            print("加载继续观看失败: \(error)")
        }
    }
}
