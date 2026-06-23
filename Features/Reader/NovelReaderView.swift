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
                    initialPage: currentPage,
                    onPageChanged: { page in
                        currentPage = page
                        // 尝试追加下一章（无缝翻页）
                        viewModel.tryAppendNextChapter(currentPage: page, fontSize: fontSize)
                        // 检测是否已翻入下一章
                        viewModel.advanceToNextChapter(currentPage: page, fontSize: fontSize)

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
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            // 从 UserDefaults 恢复字号设置（避免在 @State 初始化时产生副作用）
            fontSize = UserDefaults.standard.double(forKey: UserDefaultsKey.novelFontSize).clamped(to: 12...30, default: 17)
            // 以本地记录为准，没有记录则用 initialChapter
            let savedChapter = recordManager.load(comicId: viewModel.currentComicId.isEmpty ? comicId : viewModel.currentComicId)?.chapter ?? initialChapter
            await viewModel.load(comicId: comicId, chapter: savedChapter, fontSize: fontSize, groupContext: groupContext)
            restorePosition()
        }
        .onDisappear {
            saveRecord()
            Task { await viewModel.saveProgress() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                saveRecord()
            }
        }
        .onChange(of: viewModel.pages.count) { _, _ in
            restorePosition()
        }
        .onChange(of: viewModel.currentChapter) { _, _ in
            // 后备恢复（pages.count 不变时不会触发上面的 handler）
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                restorePosition()
            }
        }
        .onChange(of: fontSize) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKey.novelFontSize)
            viewModel.repaginate(fontSize: newValue)
        }
        .onTapGesture { showOverlay.toggle() }
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

    // MARK: - 恢复阅读位置

    private func restorePosition() {
        let count = viewModel.pages.count
        guard count > 0 else { return }

        // 无缝章节切换时跳过位置恢复
        if viewModel.isSeamlessTransition {
            viewModel.isSeamlessTransition = false
            restoredChapter = viewModel.currentChapter
            return
        }

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
            isAtChapterEnd: currentPage >= (viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0) + viewModel.currentChapterPageCount() - 1,
            hasPrevChapter: viewModel.currentChapter > 0 || viewModel.groupContext?.previousVolumeId != nil,
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
                    .foregroundStyle(darkMode ? .white : .primary)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
            }

            Spacer()

            VStack(spacing: 2) {
                Text("第 \(currentChapter + 1) 章")
                    .font(.callout.weight(.medium))
                Text("\(relativePage) / \(chapterPageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(darkMode ? .white : .primary)

            Spacer()

            Button(action: onToggleDarkMode) {
                Image(systemName: darkMode ? "sun.max" : "moon")
                    .font(.title3)
                    .foregroundStyle(darkMode ? .white : .primary)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(
            (darkMode ? Color.black : Color.white)
                .opacity(0.8)
                .ignoresSafeArea(edges: .top)
        )
    }
}

// MARK: - 小说阅读器底部覆盖层

struct NovelBottomOverlay: View {
    @Binding var fontSize: Double
    let isAtChapterEnd: Bool
    let hasPrevChapter: Bool
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("A").font(.caption2)
                Slider(value: $fontSize, in: 12...30, step: 1)
                    .tint(Color.accentColor)
                Text("A").font(.title3.weight(.bold))
                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
            .padding(.horizontal, 24)

            HStack {
                Button(action: onPrevChapter) {
                    Label("上一章", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .disabled(!hasPrevChapter)

                Spacer()

                Button(action: onShowChapterList) {
                    Label("目录", systemImage: "list.bullet")
                        .font(.subheadline)
                }

                Spacer()

                Button(action: onNextChapter) {
                    Label("下一章", systemImage: "chevron.right")
                        .font(isAtChapterEnd ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(isAtChapterEnd ? .white : .primary)
                        .padding(.horizontal, isAtChapterEnd ? 16 : 0)
                        .padding(.vertical, isAtChapterEnd ? 8 : 0)
                        .background(isAtChapterEnd ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 16)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial.opacity(0.8))
    }
}

// MARK: - 目录弹窗

struct ChapterListView: View {
    let totalChapters: Int
    let currentChapter: Int
    let chapterTitles: [Int: String]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // 章节列表在切换漫画时整体重建，index-based identity 不会导致 diff 异常
                    ForEach(0..<totalChapters, id: \.self) { index in
                        Button {
                            onSelect(index)
                        } label: {
                            HStack {
                                Text(chapterTitles[index] ?? "第 \(index + 1) 章")
                                    .foregroundStyle(index == currentChapter ? Color.accentColor : .primary)
                                    .fontWeight(index == currentChapter ? .semibold : .regular)
                                    .lineLimit(1)
                                Spacer()
                                if index == currentChapter {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
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
}

// MARK: - 翻页控制器

struct NovelPager: UIViewControllerRepresentable {
    let pages: [String]
    let fontSize: Double
    let darkMode: Bool
    let chapterTitle: String?
    let initialPage: Int
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
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard !pages.isEmpty else { return }

        let oldCount = coord.cachedVCs.count
        let newCount = pages.count

        // 检测是否为追加（新页面以旧页面开头，仅尾部新增）
        let isAppend = newCount > oldCount
            && oldCount > 0
            && coord.cachedVCs.first?.pageText == pages.first
            && coord.cachedVCs.last?.pageText == pages[oldCount - 1]

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
            let pagesChanged = oldCount != newCount
                || coord.cachedVCs.first?.pageText != pages.first
                || coord.cachedVCs.last?.pageText != pages.last

            let pageJumped = initialPage != coord.currentIndex

            if pagesChanged {
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

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: NovelPager
        var cachedVCs: [NovelTextPageVC] = []
        var currentIndex: Int = 0

        init(_ parent: NovelPager) {
            self.parent = parent
        }

        func rebuildCache(pages: [String], fontSize: Double, darkMode: Bool, title: String?) {
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
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
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

    /// 各章节的起始页索引 [章节号: 在 pages 中的起始位置]
    private(set) var chapterPageOffsets: [Int: Int] = [:]
    /// 下一章页面是否已追加
    private(set) var nextChapterAppended = false
    /// 是否正在进行无缝章节切换（跳过位置恢复）
    var isSeamlessTransition = false

    var plainText: String { chapterContent?.content ?? "" }
    private var comicId = ""
    private let api = APIClient.shared
    private let cache = ChapterCache()
    nonisolated(unsafe) private var cacheObserver: Any?

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

    // MARK: - 屏幕尺寸（供分页使用）

    /// 缓存的分页尺寸，首次使用时计算一次
    private var cachedPageSize: (maxW: CGFloat, maxH: CGFloat)?

    private var pageSize: (maxW: CGFloat, maxH: CGFloat) {
        if let cached = cachedPageSize { return cached }
        let size = computePageSize()
        cachedPageSize = size
        return size
    }

    private func computePageSize() -> (maxW: CGFloat, maxH: CGFloat) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.keyWindow else {
            // 回退到屏幕尺寸
            let screen = UIScreen.main.bounds
            return (screen.width - 40, screen.height - 40)
        }
        let width = window.bounds.width
        let height = window.bounds.height
        let safeAreaTop = window.safeAreaInsets.top
        return (width - 40, height - safeAreaTop - 40)
    }

    // MARK: - 缓存便捷方法

    private func applyFromCache(chapter: Int, fontSize: Double) -> Bool {
        guard let cached = cache.get(chapter) else { return false }
        chapterContent = cached
        currentChapter = chapter
        chapterTitles = cache.chapterTitles
        repaginate(fontSize: fontSize)
        return true
    }

    // MARK: - 加载

    func load(comicId: String, chapter: Int, fontSize: Double = 17, groupContext: ReadingGroupContext? = nil) async {
        self.comicId = comicId
        self.currentComicId = comicId
        self.groupContext = groupContext

        if applyFromCache(chapter: chapter, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }

        self.currentChapter = chapter
        isLoading = true
        do {
            chapterContent = try await api.fetchChapter(comicId: comicId, index: chapter)
            if let content = chapterContent {
                cache.put(content, for: chapter)
            }
            if let t = chapterContent?.totalChapters {
                totalChapters = t
            }
            if totalChapters == 0 || cache.chapterTitles.isEmpty {
                if let pageList = try? await api.fetchPages(comicId: comicId) {
                    totalChapters = pageList.totalPages
                    cache.extractTitles(from: pageList)
                    chapterTitles = cache.chapterTitles
                }
            }
            cache.evict(keeping: chapter)
            repaginate(fontSize: fontSize)
        } catch {
            AppLogger.error("加载章节失败: \(error)")
        }
        isLoading = false

        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    func loadVolume(comicId: String, chapter: Int, fontSize: Double = 17) async {
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
            let pageList = try await api.fetchPages(comicId: comicId)
            self.totalChapters = max(1, pageList.totalPages)
            cache.extractTitles(from: pageList)
            chapterTitles = cache.chapterTitles
            let safeChapter = min(chapter, self.totalChapters - 1)
            chapterContent = try await api.fetchChapter(comicId: comicId, index: safeChapter)
            if let content = chapterContent {
                cache.put(content, for: safeChapter)
            }
            currentChapter = safeChapter
            repaginate(fontSize: fontSize)
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
        if applyFromCache(chapter: nextIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: nextIndex, fontSize: fontSize)
    }

    func prevChapter(fontSize: Double = 17) async {
        guard currentChapter > 0 else {
            guard let prevId = groupContext?.previousVolumeId else { return }
            if let pageList = try? await api.fetchPages(comicId: prevId) {
                let lastChapter = max(0, pageList.totalPages - 1)
                await loadVolume(comicId: prevId, chapter: lastChapter, fontSize: fontSize)
            }
            return
        }
        let prevIndex = currentChapter - 1
        if applyFromCache(chapter: prevIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: prevIndex, fontSize: fontSize)
    }

    func saveProgress(currentPage: Int = 0) async {
        try? await api.updateProgress(comicId: currentComicId, page: currentChapter)
    }

    // MARK: - 分页

    func repaginate(fontSize: Double) {
        currentChapterTitle = chapterContent?.title
        let size = pageSize
        let titleHeight: CGFloat = (chapterContent?.title != nil) ? fontSize * 2.5 : 0
        let newPages = PaginationService.paginate(
            text: plainText, fontSize: fontSize,
            maxWidth: size.maxW, maxHeight: size.maxH,
            firstPageMaxH: size.maxH - titleHeight
        )
        chapterPageOffsets = [currentChapter: 0]
        nextChapterAppended = false
        pages = newPages
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

        Task {
            let size = pageSize
            let appendPages: [String]
            if let nextContent = cache.get(nextIndex) {
                appendPages = PaginationService.paginateContent(nextContent, fontSize: fontSize, maxWidth: size.maxW, maxHeight: size.maxH)
            } else {
                do {
                    let content = try await api.fetchChapter(comicId: comicId, index: nextIndex)
                    cache.put(content, for: nextIndex)
                    appendPages = PaginationService.paginateContent(content, fontSize: fontSize, maxWidth: size.maxW, maxHeight: size.maxH)
                } catch {
                    AppLogger.error("追加下一章失败: \(error)")
                    nextChapterAppended = false
                    return
                }
            }
            let startIdx = pages.count
            chapterPageOffsets[nextIndex] = startIdx
            pages.append(contentsOf: appendPages)
        }
    }

    func advanceToNextChapter(currentPage: Int, fontSize: Double) {
        let nextIndex = currentChapter + 1
        guard let nextOffset = chapterPageOffsets[nextIndex] else { return }
        guard currentPage >= nextOffset else { return }

        if let cached = cache.get(nextIndex) {
            currentChapterTitle = cached.title
        }
        isSeamlessTransition = true
        currentChapter = nextIndex
        nextChapterAppended = false
        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }
}

// MARK: - Extensions
