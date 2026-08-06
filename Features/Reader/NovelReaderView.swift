import SwiftUI
import UIKit

// MARK: - 小说阅读器（SwiftUI 入口）

struct NovelReaderView: View {
    let comicId: String
    let initialChapter: Int
    var groupContext: ReadingGroupContext? = nil

    @State private var viewModel = NovelReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = false
    @State private var showChapterList = false
    @State private var fontSize: Double = 17
    @State private var currentPage = 0
    private let recordManager: ReadingRecordManager = ReadingRecordManager.shared
    @State private var restoredChapter = -1

    var body: some View {
        GeometryReader { geometry in
            let paginationSize = CGSize(
                width: max(1, geometry.size.width - 32),
                height: max(
                    1,
                    geometry.size.height
                        - geometry.safeAreaInsets.top
                        - 32
                )
            )

            ZStack {
                backgroundForTheme.ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.pages.isEmpty {
                    NovelPager(
                        pages: viewModel.pages,
                        fontSize: fontSize,
                        darkMode: viewModel.darkMode,
                        chapterTitle: viewModel.currentChapterTitle,
                        paginationGeneration: viewModel.paginationGeneration,
                        initialPage: currentPage,
                        isPageInteractionEnabled: !showOverlay,
                        onPageChanged: { page in
                            currentPage = page
                            // 尝试追加下一章（无缝翻页）
                            viewModel.tryAppendNextChapter(currentPage: page, fontSize: fontSize)
                            // 检测是否已翻入下一章
                            viewModel.advanceToNextChapter(currentPage: page, fontSize: fontSize)
                            viewModel.updateActivityProgress()

                            // 保存记录（使用相对页码）
                            let relPage = viewModel.relativePageInChapter(page)
                            recordManager.save(
                                comicId: viewModel.currentComicId,
                                chapter: viewModel.currentChapter,
                                page: relPage
                            )
                        },
                        onReachEnd: {
                            // 兜底：如果追加还没完成，手动切章
                            if !viewModel.nextChapterAppended {
                                showOverlay = false
                                saveRecord()
                                currentPage = 0
                                Task { await viewModel.nextChapter(fontSize: fontSize) }
                            }
                        },
                        onSwipeToPrev: {
                            showOverlay = false
                            let currentComicId = viewModel.currentComicId
                            let currentChapter = viewModel.currentChapter
                            recordManager.save(comicId: currentComicId, chapter: currentChapter, page: currentPage)
                            currentPage = 99999
                            Task { await viewModel.prevChapter(fontSize: fontSize) }
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .task {
                // 从 UserDefaults 恢复字号设置（避免在 @State 初始化时产生副作用）
                fontSize = UserDefaults.standard.double(forKey: UserDefaultsKey.novelFontSize).clamped(to: 12...30, default: 17)
                viewModel.setPaginationSize(paginationSize)
                // 以本地记录为准，没有记录则用 initialChapter
                let savedChapter = recordManager.load(comicId: viewModel.currentComicId.isEmpty ? comicId : viewModel.currentComicId)?.chapter ?? initialChapter
                await viewModel.load(comicId: comicId, chapter: savedChapter, fontSize: fontSize, groupContext: groupContext)
                restorePosition()
            }
            .onDisappear {
                saveRecord()
                Task { await viewModel.finishActivity() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.resumeActivity()
                } else if newPhase == .background || newPhase == .inactive {
                    saveRecord()
                    viewModel.pauseActivity()
                    Task { await viewModel.saveProgress() }
                }
            }
            .onChange(of: paginationSize) { _, newSize in
                Task {
                    await viewModel.updatePaginationSize(newSize, fontSize: fontSize)
                }
            }
            .onChange(of: viewModel.paginationGeneration) { _, _ in
                restorePosition()
            }
            .onChange(of: fontSize) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.novelFontSize)
            }
            .overlay {
                Color.clear
                    .frame(width: max(88, geometry.size.width * 0.4))
                    .contentShape(Rectangle())
                    .onTapGesture { showOverlay.toggle() }
            }
            .overlay(alignment: .top) {
                topOverlay
                    .opacity(showOverlay ? 1 : 0)
                    .allowsHitTesting(showOverlay)
            }
            .overlay(alignment: .bottom) {
                bottomOverlay
                    .opacity(showOverlay ? 1 : 0)
                    .allowsHitTesting(showOverlay)
            }
            .sheet(isPresented: $showChapterList) {
                ChapterListView(
                    totalChapters: viewModel.totalChapters,
                    currentChapter: viewModel.currentChapter,
                    chapters: viewModel.chapterEntries,
                    chapterTitles: viewModel.chapterTitles,
                    onSelect: { index in
                        showChapterList = false
                        showOverlay = false
                        saveRecord()
                        currentPage = 0
                        Task { await viewModel.load(comicId: viewModel.currentComicId, chapter: index, fontSize: fontSize) }
                    }
                )
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
        .readerStatusBarHidden(true)
    }

    // MARK: - 恢复阅读位置

    private func restorePosition() {
        let count = viewModel.pages.count
        guard count > 0 else { return }
        currentPage = min(max(currentPage, 0), count - 1)

        guard restoredChapter != viewModel.currentChapter else { return }
        restoredChapter = viewModel.currentChapter

        if let record = recordManager.load(comicId: viewModel.currentComicId),
           record.chapter == viewModel.currentChapter {
            // 有记录：恢复到上次位置（覆盖 99999）
            currentPage = min(record.page, count - 1)
        }
        // 无记录：保留 currentPage（前翻=0，回翻=99999→clamp 到末页）
    }

    // MARK: - 保存记录

    private func saveRecord() {
        let relPage = viewModel.relativePageInChapter(currentPage)
        recordManager.save(
            comicId: viewModel.currentComicId,
            chapter: viewModel.currentChapter,
            page: relPage
        )
    }

    // MARK: - UI

    private var backgroundForTheme: Color {
        viewModel.darkMode ? Color(white: 0.1) : Color(.systemBackground)
    }

    // 轻量覆盖层：闭包每次 body 求值时重建，但视图简单，不会引起可见问题
    private var topOverlay: some View {
        NovelTopOverlay(
            darkMode: viewModel.darkMode,
            currentChapter: viewModel.currentChapter,
            relativePage: viewModel.relativePageInChapter(currentPage),
            chapterPageCount: viewModel.currentChapterPageCount(),
            onDismiss: { dismiss() },
            onToggleDarkMode: { viewModel.darkMode.toggle() }
        )
    }

    // 轻量覆盖层：闭包每次 body 求值时重建，但视图简单，不会引起可见问题
    private var bottomOverlay: some View {
        NovelBottomOverlay(
            fontSize: $fontSize,
            darkMode: viewModel.darkMode,
            isAtChapterEnd: currentPage
                >= (viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0)
                    + viewModel.currentChapterPageCount() - 1,
            hasPrevChapter: viewModel.currentChapter > 0 || viewModel.groupContext?.previousVolumeId != nil,
            onFontSizeCommit: {
                Task { await viewModel.repaginate(fontSize: fontSize) }
            },
            onPrevChapter: {
                showOverlay = false
                saveRecord()
                currentPage = 99999
                Task { await viewModel.prevChapter(fontSize: fontSize) }
            },
            onNextChapter: {
                showOverlay = false
                saveRecord()
                currentPage = 0
                Task { await viewModel.nextChapter(fontSize: fontSize) }
            },
            onShowChapterList: { showChapterList = true }
        )
    }
}

// MARK: - 小说阅读器顶部覆盖层

struct NovelTopOverlay: View {
    let darkMode: Bool
    let currentChapter: Int
    let relativePage: Int
    let chapterPageCount: Int
    let onDismiss: () -> Void
    let onToggleDarkMode: () -> Void

    var body: some View {
        HStack {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("第 \(currentChapter + 1) 章")
                    .font(.callout.weight(.medium))
                Text("\(relativePage) / \(chapterPageCount)")
                    .font(.caption2)
                    .opacity(0.72)
            }

            Spacer()

            Button(action: onToggleDarkMode) {
                Image(systemName: darkMode ? "sun.max" : "moon")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(darkMode ? Color.white : Color.primary)
        .shadow(
            color: darkMode ? Color.black.opacity(0.8) : Color.white.opacity(0.95),
            radius: 2
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - 小说阅读器底部覆盖层

struct NovelBottomOverlay: View {
    @Binding var fontSize: Double
    let darkMode: Bool
    let isAtChapterEnd: Bool
    let hasPrevChapter: Bool
    let onFontSizeCommit: () -> Void
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("A").font(.caption2)
                Slider(
                    value: $fontSize,
                    in: 12...30,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            onFontSizeCommit()
                        }
                    }
                )
                    .tint(Color.accentColor)
                Text("A").font(.title3.weight(.bold))
                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .opacity(0.72)
                    .frame(width: 28)
            }
            .padding(.horizontal, 24)

            HStack {
                Button(action: onPrevChapter) {
                    Label("上一章", systemImage: "chevron.left")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!hasPrevChapter)

                Spacer()

                Button(action: onShowChapterList) {
                    Label("目录", systemImage: "list.bullet")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onNextChapter) {
                    Label("下一章", systemImage: "chevron.right")
                        .font(isAtChapterEnd ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(isAtChapterEnd ? Color.accentColor : controlForeground)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(controlForeground)
        .shadow(
            color: darkMode ? Color.black.opacity(0.8) : Color.white.opacity(0.95),
            radius: 2
        )
        .padding(.vertical, 16)
        .padding(.bottom, 8)
    }

    private var controlForeground: Color {
        darkMode ? .white : .primary
    }
}

// MARK: - 目录弹窗

private struct ChapterListRow: Identifiable {
    let id: Int
    let title: String
    let level: Int
    let parentIndex: Int?
    let hasChildren: Bool
}

struct ChapterListView: View {
    let totalChapters: Int
    let currentChapter: Int
    let chapters: [PageEntry]
    let chapterTitles: [Int: String]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var collapsedIndexes = Set<Int>()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(visibleRows) { row in
                        HStack(spacing: 6) {
                            if row.hasChildren {
                                Button {
                                    toggleCollapsed(row.id)
                                } label: {
                                    Image(
                                        systemName: collapsedIndexes.contains(row.id)
                                            ? "chevron.right"
                                            : "chevron.down"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 20, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    collapsedIndexes.contains(row.id) ? "展开" : "折叠"
                                )
                            } else {
                                Color.clear
                                    .frame(width: 20, height: 28)
                                    .accessibilityHidden(true)
                            }

                            Button {
                                onSelect(row.id)
                            } label: {
                                HStack {
                                    Text(row.title)
                                        .foregroundStyle(
                                            row.id == currentChapter
                                                ? Color.accentColor
                                                : .primary
                                        )
                                        .fontWeight(
                                            row.id == currentChapter
                                                ? .semibold
                                                : .regular
                                        )
                                        .lineLimit(2)
                                    Spacer()
                                    if row.id == currentChapter {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, CGFloat(min(row.level, 6)) * 14)
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentChapter)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var rows: [ChapterListRow] {
        let entries: [PageEntry]
        if chapters.isEmpty {
            entries = (0..<totalChapters).map {
                PageEntry(
                    index: $0,
                    name: nil,
                    url: nil,
                    title: chapterTitles[$0],
                    level: nil,
                    parentIndex: nil,
                    hasChildren: nil
                )
            }
        } else {
            entries = chapters
        }

        var ancestors: [Int] = []
        var provisional: [(entry: PageEntry, level: Int, parent: Int?)] = []
        for entry in entries {
            let level = min(max(0, entry.level ?? 0), ancestors.count)
            while ancestors.count > level {
                ancestors.removeLast()
            }
            let inferredParent = level > 0 ? ancestors.last : nil
            let explicitParent = entry.parentIndex.flatMap { $0 >= 0 ? $0 : nil }
            provisional.append((entry, level, explicitParent ?? inferredParent))
            ancestors.append(entry.index)
        }

        let parentIndexes = Set(provisional.compactMap(\.parent))
        return provisional.enumerated().map { offset, item in
            let title = nonempty(item.entry.title)
                ?? nonempty(item.entry.name)
                ?? chapterTitles[item.entry.index]
                ?? "第 \(item.entry.index + 1) 章"
            let nextIsChild = provisional.indices.contains(offset + 1)
                && provisional[offset + 1].level > item.level
            return ChapterListRow(
                id: item.entry.index,
                title: title,
                level: item.level,
                parentIndex: item.parent,
                hasChildren: item.entry.hasChildren
                    ?? (parentIndexes.contains(item.entry.index) || nextIsChild)
            )
        }
    }

    private var visibleRows: [ChapterListRow] {
        let allRows = rows
        let rowsByIndex = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
        return allRows.filter { row in
            var parent = row.parentIndex
            var visited = Set<Int>()
            while let parentIndex = parent, visited.insert(parentIndex).inserted {
                if collapsedIndexes.contains(parentIndex) {
                    return false
                }
                parent = rowsByIndex[parentIndex]?.parentIndex
            }
            return true
        }
    }

    private func toggleCollapsed(_ index: Int) {
        if collapsedIndexes.contains(index) {
            collapsedIndexes.remove(index)
        } else {
            collapsedIndexes.insert(index)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - 翻页控制器

struct NovelPager: UIViewControllerRepresentable {
    let pages: [String]
    let fontSize: Double
    let darkMode: Bool
    let chapterTitle: String?
    let paginationGeneration: Int
    let initialPage: Int
    let isPageInteractionEnabled: Bool
    let onPageChanged: (Int) -> Void
    let onReachEnd: () -> Void
    let onSwipeToPrev: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false
        pvc.view.isUserInteractionEnabled = isPageInteractionEnabled
        pvc.view.backgroundColor = pageBackgroundColor
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        pvc.view.isUserInteractionEnabled = isPageInteractionEnabled
        pvc.view.backgroundColor = pageBackgroundColor
        let coord = context.coordinator
        coord.parent = self
        guard !pages.isEmpty else { return }

        let oldCount = coord.cachedVCs.count
        let newCount = pages.count
        let renderConfiguration = Coordinator.RenderConfiguration(
            fontSize: fontSize,
            darkMode: darkMode
        )
        let configurationChanged = coord.renderConfiguration != renderConfiguration

        // 检测是否为追加（新页面以旧页面开头，仅尾部新增）
        let isAppend = newCount > oldCount
            && oldCount > 0
            && !configurationChanged
            && coord.paginationGeneration == paginationGeneration

        if isAppend {
            // 追加模式：只添加新页面的 VC，不重置当前位置
            for i in oldCount..<newCount {
                let title: String? = (i == 0) ? chapterTitle : nil
                let vc = NovelTextPageVC(
                    text: pages[i],
                    index: i,
                    fontSize: fontSize,
                    darkMode: darkMode,
                    title: title
                )
                coord.cachedVCs.append(vc)
            }
            // 不调用 setViewControllers，保持当前翻页位置
        } else {
            // 完全替换（切章、字号变化等）
            let pagesChanged = coord.paginationGeneration != paginationGeneration

            let pageJumped = initialPage != coord.currentIndex

            if pagesChanged || configurationChanged {
                coord.rebuildCache(pages: pages, fontSize: fontSize, darkMode: darkMode, title: chapterTitle)
                let page = min(initialPage, coord.cachedVCs.count - 1)
                if page >= 0, page < coord.cachedVCs.count {
                    pvc.setViewControllers([coord.cachedVCs[page]], direction: .forward, animated: false)
                    coord.currentIndex = page
                }
            } else if pageJumped {
                let page = min(initialPage, coord.cachedVCs.count - 1)
                if page >= 0, page < coord.cachedVCs.count {
                    pvc.setViewControllers([coord.cachedVCs[page]], direction: .forward, animated: false)
                    coord.currentIndex = page
                }
            }
        }
    }

    private var pageBackgroundColor: UIColor {
        darkMode ? UIColor(white: 0.1, alpha: 1) : .systemBackground
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: NovelPager
        var cachedVCs: [NovelTextPageVC] = []
        var currentIndex: Int = 0
        var paginationGeneration = -1
        var renderConfiguration: RenderConfiguration?

        struct RenderConfiguration: Equatable {
            let fontSize: Double
            let darkMode: Bool
        }

        init(_ parent: NovelPager) {
            self.parent = parent
        }

        func rebuildCache(pages: [String], fontSize: Double, darkMode: Bool, title: String?) {
            paginationGeneration = parent.paginationGeneration
            renderConfiguration = RenderConfiguration(fontSize: fontSize, darkMode: darkMode)
            cachedVCs = pages.enumerated().map { index, text in
                NovelTextPageVC(
                    text: text,
                    index: index,
                    fontSize: fontSize,
                    darkMode: darkMode,
                    title: index == 0 ? title : nil
                )
            }
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? NovelTextPageVC else { return nil }
            let prev = page.index - 1
            if prev < 0 {
                DispatchQueue.main.async { self.parent.onSwipeToPrev() }
                return nil
            }
            return cachedVCs[safe: prev]
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? NovelTextPageVC else { return nil }
            let next = page.index + 1
            if next >= cachedVCs.count {
                DispatchQueue.main.async { self.parent.onReachEnd() }
                return nil
            }
            return cachedVCs[safe: next]
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? NovelTextPageVC else { return }
            currentIndex = current.index
            parent.onPageChanged(current.index)
        }
    }
}

// MARK: - 单页 VC

class NovelTextPageVC: UIViewController {
    let pageText: String
    let index: Int
    let fontSize: Double
    let darkMode: Bool
    let titleText: String?

    private let label = UILabel()

    init(text: String, index: Int, fontSize: Double, darkMode: Bool, title: String?) {
        self.pageText = text
        self.index = index
        self.fontSize = fontSize
        self.darkMode = darkMode
        self.titleText = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = darkMode ? UIColor(white: 0.1, alpha: 1) : .systemBackground

        label.numberOfLines = 0
        label.backgroundColor = .clear

        let textColor: UIColor = darkMode ? .white.withAlphaComponent(0.9) : .label
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.6

        var fullText = pageText
        if let title = titleText {
            fullText = title + "\n\n" + pageText
        }

        let attr = NSMutableAttributedString(string: fullText, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ])

        if let title = titleText {
            let range = (fullText as NSString).range(of: title)
            attr.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize + 4), range: range)
        }

        label.attributedText = attr
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -16
            ),
        ])
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let novelChapterCacheClear = Notification.Name("novelChapterCacheClear")
}

// MARK: - ViewModel

@MainActor
@Observable
final class NovelReaderViewModel {
    var chapterContent: ChapterContent?
    var isLoading = false
    var currentChapter = 0
    var totalChapters: Int = 0
    var currentChapterTitle: String? = nil
    var darkMode = false
    var pages: [String] = []
    var groupContext: ReadingGroupContext?
    var currentComicId: String
    var chapterTitles: [Int: String] = [:]
    var chapterEntries: [PageEntry] = []
    private(set) var paginationGeneration = 0

    /// 各章节的起始页索引 [章节号: 在 pages 中的起始位置]
    private(set) var chapterPageOffsets: [Int: Int] = [:]
    /// 下一章页面是否已追加
    private(set) var nextChapterAppended = false

    private var comicId = ""
    private let api = APIClient.shared
    private let cache = ChapterCache()
    private var activityTracker: ReadingActivityTracker?
    @ObservationIgnored private var cacheObserver: Any?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var appendPaginationTask: Task<Void, Never>?
    private var paginationRequestID = UUID()
    private var appendPaginationRequestID: UUID?
    private var appendedChapterContent: ChapterContent?
    private var paginationSize = CGSize(width: 320, height: 640)

    init() {
        self.currentComicId = ""
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .novelChapterCacheClear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cache.clear()
            }
        }
    }

    deinit {
        if let observer = cacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 分页尺寸

    func setPaginationSize(_ size: CGSize) {
        paginationSize = normalizedPaginationSize(size)
    }

    func updatePaginationSize(_ size: CGSize, fontSize: Double) async {
        let normalized = normalizedPaginationSize(size)
        guard abs(normalized.width - paginationSize.width) > 0.5
                || abs(normalized.height - paginationSize.height) > 0.5 else {
            return
        }
        paginationSize = normalized
        guard chapterContent != nil else { return }
        await repaginate(fontSize: fontSize)
    }

    private func normalizedPaginationSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    // MARK: - 缓存便捷方法

    private func applyFromCache(chapter: Int, fontSize: Double) async -> Bool {
        guard let cached = cache.get(chapter) else { return false }
        isLoading = true
        chapterContent = cached
        currentChapter = chapter
        chapterTitles = cache.chapterTitles
        chapterEntries = cache.chapterEntries
        await repaginate(fontSize: fontSize)
        updateActivityProgress()
        isLoading = false
        return true
    }

    // MARK: - 加载

    func load(comicId: String, chapter: Int, fontSize: Double = 17, groupContext: ReadingGroupContext? = nil) async {
        let isSwitchingComic = !currentComicId.isEmpty && currentComicId != comicId
        if isSwitchingComic {
            await finishActivity()
            cache.clear()
            chapterTitles = [:]
            chapterEntries = []
            totalChapters = 0
        }
        self.comicId = comicId
        self.currentComicId = comicId
        if let groupContext {
            self.groupContext = groupContext
        }

        if await applyFromCache(chapter: chapter, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }

        self.currentChapter = chapter
        isLoading = true
        do {
            chapterContent = try await loadChapterContent(
                comicId: comicId,
                index: chapter
            )
            if let content = chapterContent {
                cache.put(content, for: chapter)
            }
            if let t = chapterContent?.totalChapters {
                totalChapters = t
            }
            if totalChapters == 0 || cache.chapterEntries.isEmpty {
                if let pageList = await loadPageList(comicId: comicId) {
                    totalChapters = pageList.totalPages
                    cache.extractTitles(from: pageList)
                    chapterTitles = cache.chapterTitles
                    chapterEntries = cache.chapterEntries
                }
            }
            cache.evict(keeping: chapter)
            await repaginate(fontSize: fontSize)
            updateActivityProgress()
        } catch {
            AppLogger.error("加载章节失败: \(error)")
        }
        isLoading = false

        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    func loadVolume(comicId: String, chapter: Int, fontSize: Double = 17) async {
        await finishActivity()

        if let ctx = groupContext,
           let newIdx = ctx.volumeIds.firstIndex(of: comicId) {
            groupContext = ReadingGroupContext(
                groupId: ctx.groupId,
                volumeIds: ctx.volumeIds,
                currentIndex: newIdx
            )
        }

        self.comicId = comicId
        self.currentComicId = comicId
        self.currentChapter = chapter
        isLoading = true
        cache.clear()

        do {
            guard let pageList = await loadPageList(comicId: comicId) else {
                throw APIError.dataFormat
            }
            self.totalChapters = max(1, pageList.totalPages)
            cache.extractTitles(from: pageList)
            chapterTitles = cache.chapterTitles
            chapterEntries = cache.chapterEntries
            let safeChapter = min(chapter, self.totalChapters - 1)
            chapterContent = try await loadChapterContent(
                comicId: comicId,
                index: safeChapter
            )
            if let content = chapterContent {
                cache.put(content, for: safeChapter)
            }
            currentChapter = safeChapter
            await repaginate(fontSize: fontSize)
            updateActivityProgress()
        } catch {
            AppLogger.error("加载卷失败: \(error)")
        }
        isLoading = false

        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    func nextChapter(fontSize: Double = 17) async {
        let nextIndex = currentChapter + 1
        if totalChapters > 0 && nextIndex >= totalChapters {
            guard let nextId = groupContext?.nextVolumeId else { return }
            await loadVolume(comicId: nextId, chapter: 0, fontSize: fontSize)
            return
        }
        if await applyFromCache(chapter: nextIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: nextIndex, fontSize: fontSize)
    }

    func prevChapter(fontSize: Double = 17) async {
        guard currentChapter > 0 else {
            guard let prevId = groupContext?.previousVolumeId else { return }
            if let pageList = await loadPageList(comicId: prevId) {
                let lastChapter = max(0, pageList.totalPages - 1)
                await loadVolume(comicId: prevId, chapter: lastChapter, fontSize: fontSize)
            }
            return
        }
        let prevIndex = currentChapter - 1
        if await applyFromCache(chapter: prevIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: prevIndex, fontSize: fontSize)
    }

    func saveProgress(currentPage: Int = 0) async {
        updateActivityProgress()
        do {
            try await activityTracker?.flush(finalize: false)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
    }

    func finishActivity() async {
        updateActivityProgress()
        do {
            try await activityTracker?.flush(finalize: true)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
        activityTracker = nil
    }

    func pauseActivity() {
        activityTracker?.setActive(false)
    }

    func resumeActivity() {
        activityTracker?.setActive(true)
    }

    func updateActivityProgress() {
        guard totalChapters > 0, !currentComicId.isEmpty else { return }
        let safeChapter = min(max(currentChapter, 0), max(totalChapters - 1, 0))
        if activityTracker?.comicId != currentComicId {
            activityTracker = ReadingActivityTracker(comicId: currentComicId)
            activityTracker?.start(page: safeChapter, totalPages: totalChapters)
        } else {
            activityTracker?.updatePage(page: safeChapter, totalPages: totalChapters)
        }
    }

    // MARK: - 分页

    func repaginate(fontSize: Double) async {
        guard let content = chapterContent else { return }

        appendPaginationRequestID = nil
        appendPaginationTask?.cancel()
        appendPaginationTask = nil
        appendedChapterContent = nil

        paginationTask?.cancel()
        let requestID = UUID()
        paginationRequestID = requestID

        let rawContent = content.content ?? ""
        let mimeType = content.mimeType
        let title = content.title
        let chapter = currentChapter
        let size = paginationSize
        let titleHeight: CGFloat = title == nil ? 0 : fontSize * 2.5
        currentChapterTitle = title

        let worker = Task.detached(priority: .userInitiated) {
            let text = PaginationService.readableText(
                content: rawContent,
                mimeType: mimeType
            )
            return PaginationService.paginate(
                text: text,
                fontSize: fontSize,
                maxWidth: size.width,
                maxHeight: size.height,
                firstPageMaxH: size.height - titleHeight
            )
        }

        let task = Task { @MainActor [weak self] in
            let newPages = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.paginationRequestID == requestID else {
                return
            }
            self.chapterPageOffsets = [chapter: 0]
            self.nextChapterAppended = false
            self.pages = newPages
            self.paginationGeneration += 1
        }
        paginationTask = task
        await task.value
    }

    func relativePageInChapter(_ absolutePage: Int) -> Int {
        let offset = chapterPageOffsets[currentChapter] ?? 0
        return max(1, absolutePage - offset + 1)
    }

    func currentChapterPageCount() -> Int {
        let offset = chapterPageOffsets[currentChapter] ?? 0
        let nextOffset = chapterPageOffsets[currentChapter + 1] ?? pages.count
        return max(1, nextOffset - offset)
    }

    // MARK: - 无缝翻页

    func tryAppendNextChapter(currentPage: Int, fontSize: Double) {
        guard !nextChapterAppended else { return }
        let chapterEnd = chapterPageOffsets[currentChapter + 1] ?? pages.count
        let pagesRemaining = chapterEnd - currentPage
        guard pagesRemaining <= 2 else { return }

        let nextIndex = currentChapter + 1
        if totalChapters > 0 && nextIndex >= totalChapters { return }

        nextChapterAppended = true
        let requestID = UUID()
        appendPaginationRequestID = requestID
        appendPaginationTask?.cancel()
        appendPaginationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let content: ChapterContent
            if let cached = self.cache.get(nextIndex) {
                content = cached
            } else {
                do {
                    content = try await self.loadChapterContent(
                        comicId: self.comicId,
                        index: nextIndex
                    )
                    self.cache.put(content, for: nextIndex)
                } catch {
                    guard self.appendPaginationRequestID == requestID else { return }
                    AppLogger.error("追加下一章失败: \(error)")
                    self.nextChapterAppended = false
                    return
                }
            }

            let rawContent = content.content ?? ""
            let mimeType = content.mimeType
            let titleHeight: CGFloat = content.title == nil ? 0 : fontSize * 2.5
            let size = self.paginationSize
            let worker = Task.detached(priority: .utility) {
                let text = PaginationService.readableText(
                    content: rawContent,
                    mimeType: mimeType
                )
                return PaginationService.paginate(
                    text: text,
                    fontSize: fontSize,
                    maxWidth: size.width,
                    maxHeight: size.height,
                    firstPageMaxH: size.height - titleHeight
                )
            }
            let appendPages = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled,
                  self.appendPaginationRequestID == requestID,
                  self.currentChapter == nextIndex - 1 else {
                return
            }
            let startIdx = self.pages.count
            self.chapterPageOffsets[nextIndex] = startIdx
            self.pages.append(contentsOf: appendPages)
            self.appendedChapterContent = content
            self.appendPaginationRequestID = nil
            self.appendPaginationTask = nil
        }
    }

    func advanceToNextChapter(currentPage: Int, fontSize: Double) {
        let nextIndex = currentChapter + 1
        guard let nextOffset = chapterPageOffsets[nextIndex] else { return }
        guard currentPage >= nextOffset else { return }
        guard let content = appendedChapterContent ?? cache.get(nextIndex) else { return }

        chapterContent = content
        currentChapterTitle = content.title
        appendedChapterContent = nil
        currentChapter = nextIndex
        nextChapterAppended = false
        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    // MARK: - 在线与离线数据源

    private func loadChapterContent(
        comicId: String,
        index: Int
    ) async throws -> ChapterContent {
        do {
            return try await api.fetchChapter(comicId: comicId, index: index)
        } catch {
            let manager = OfflineFileManager.shared
            if let local = await Task.detached(priority: .utility, operation: {
                manager.loadNovelChapter(comicId: comicId, chapter: index)
            }).value {
                AppLogger.log("网络不可用，从本地缓存加载小说章节")
                return local
            }
            throw error
        }
    }

    private func loadPageList(comicId: String) async -> PageList? {
        do {
            let pageList = try await api.fetchPages(comicId: comicId)
            let manager = OfflineFileManager.shared
            await Task.detached(priority: .utility) {
                guard manager.loadMeta(comicId: comicId)?.isNovel == true else {
                    return
                }
                try? manager.saveNovelPageList(pageList, comicId: comicId)
            }.value
            return pageList
        } catch {
            let manager = OfflineFileManager.shared
            return await Task.detached(priority: .utility) {
                if let pageList = manager.loadNovelPageList(comicId: comicId) {
                    return pageList
                }
                guard let meta = manager.loadMeta(comicId: comicId),
                      meta.isNovel == true else {
                    return nil
                }
                let pages = (0..<meta.pageCount).map {
                    PageEntry(
                        index: $0,
                        name: nil,
                        url: nil,
                        title: nil,
                        level: nil,
                        parentIndex: nil,
                        hasChildren: nil
                    )
                }
                return PageList(
                    comicId: comicId,
                    title: meta.title,
                    totalPages: meta.pageCount,
                    isNovel: true,
                    isPdf: false,
                    pages: pages
                )
            }.value
        }
    }
}

// MARK: - Extensions
