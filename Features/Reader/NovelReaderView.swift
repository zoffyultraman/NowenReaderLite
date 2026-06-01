import SwiftUI
import UIKit

// MARK: - 小说阅读器（SwiftUI 入口）

struct NovelReaderView: View {
    let comicId: String
    let initialChapter: Int
    var groupContext: ReadingGroupContext? = nil

    @StateObject private var viewModel = NovelReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = false
    @State private var showChapterList = false
    @State private var fontSize: Double = UserDefaults.standard.double(forKey: UserDefaultsKey.novelFontSize).clamped(to: 12...30, default: 17)
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
                    chapterTitle: viewModel.chapterContent?.title,
                    initialPage: currentPage,
                    onPageChanged: { page in
                        currentPage = page
                        // 每次翻页保存记录
                        recordManager.save(
                            comicId: viewModel.currentComicId,
                            chapter: viewModel.currentChapter,
                            page: page
                        )
                    },
                    onReachEnd: {
                        showOverlay = false
                        let saved = currentPage
                        let currentComicId = viewModel.currentComicId
                        let currentChapter = viewModel.currentChapter
                        recordManager.save(comicId: currentComicId, chapter: currentChapter, page: saved)
                        currentPage = 0
                        Task { await viewModel.nextChapter(fontSize: fontSize) }
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
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .task {
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
            if showOverlay { topOverlay }
        }
        .overlay(alignment: .bottom) {
            if showOverlay { bottomOverlay }
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView(
                totalChapters: viewModel.totalChapters,
                currentChapter: viewModel.currentChapter,
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
        recordManager.save(
            comicId: viewModel.currentComicId,
            chapter: viewModel.currentChapter,
            page: currentPage
        )
    }

    // MARK: - UI

    private var backgroundForTheme: Color {
        viewModel.darkMode ? Color(white: 0.1) : Color(.systemBackground)
    }

    private var topOverlay: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(viewModel.darkMode ? .white : .primary)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
            }

            Spacer()

            VStack(spacing: 2) {
                Text("第 \(viewModel.currentChapter + 1) 章")
                    .font(.callout.weight(.medium))
                Text("\(currentPage + 1) / \(viewModel.pages.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(viewModel.darkMode ? .white : .primary)

            Spacer()

            Button { viewModel.darkMode.toggle() } label: {
                Image(systemName: viewModel.darkMode ? "sun.max" : "moon")
                    .font(.title3)
                    .foregroundStyle(viewModel.darkMode ? .white : .primary)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(
            (viewModel.darkMode ? Color.black : Color.white)
                .opacity(0.8)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomOverlay: some View {
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
                Button {
                    showOverlay = false
                    saveRecord()
                    currentPage = 99999
                    Task { await viewModel.prevChapter(fontSize: fontSize) }
                } label: {
                    Label("上一章", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .disabled(viewModel.currentChapter <= 0 && viewModel.groupContext?.previousVolumeId == nil)

                Spacer()

                Button {
                    showChapterList = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                        .font(.subheadline)
                }

                Spacer()

                if currentPage >= viewModel.pages.count - 1 {
                    Button {
                        showOverlay = false
                        saveRecord()
                        currentPage = 0
                        Task { await viewModel.nextChapter(fontSize: fontSize) }
                    } label: {
                        Label("下一章", systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Button {
                        showOverlay = false
                        saveRecord()
                        currentPage = 0
                        Task { await viewModel.nextChapter(fontSize: fontSize) }
                    } label: {
                        Label("下一章", systemImage: "chevron.right")
                            .font(.subheadline)
                    }
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
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<totalChapters, id: \.self) { index in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text("第 \(index + 1) 章")
                                .foregroundStyle(index == currentChapter ? Color.accentColor : .primary)
                                .fontWeight(index == currentChapter ? .semibold : .regular)
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

        let pagesChanged = coord.cachedVCs.count != pages.count
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
            // initialPage 变了但 pages 没变（restorePosition）
            let page = min(initialPage, coord.cachedVCs.count - 1)
            if page >= 0, page < coord.cachedVCs.count {
                pvc.setViewControllers([coord.cachedVCs[page]], direction: .forward, animated: false)
                coord.currentIndex = page
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
final class NovelReaderViewModel: ObservableObject {
    @Published var chapterContent: ChapterContent?
    @Published var isLoading = false
    @Published var currentChapter = 0
    @Published var totalChapters: Int = 0
    @Published var darkMode = false
    @Published var pages: [String] = []
    @Published var groupContext: ReadingGroupContext?
    @Published var currentComicId: String

    private var cacheObserver: Any?

    init() {
        self.currentComicId = ""
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .novelChapterCacheClear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearCache()
            }
        }
    }

    deinit {
        if let observer = cacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var plainText: String { chapterContent?.content ?? "" }

    private var comicId = ""
    private let api = APIClient.shared

    // MARK: - 章节预缓存

    private var chapterCache: [Int: ChapterContent] = [:]
    private var chapterCacheBytes: Int = 0
    private let cacheCapacity = 5 // 当前 ±2

    /// 小说章节缓存总字节数（供设置页读取）
    static var totalNovelCacheBytes: Int = 0

    /// 从缓存中取出章节并应用，返回是否命中
    private func applyFromCache(chapter: Int, fontSize: Double) -> Bool {
        guard let cached = chapterCache[chapter] else { return false }
        chapterContent = cached
        currentChapter = chapter
        repaginate(fontSize: fontSize)
        return true
    }

    /// 预加载当前章节 ±2 的相邻章节
    private func preloadAdjacentChapters(fontSize: Double) {
        let center = currentChapter

        for offset in [-2, -1, 1, 2] {
            let target = center + offset
            guard target >= 0 else { continue }
            if totalChapters > 0 && target >= totalChapters { continue }
            guard chapterCache[target] == nil else { continue }

            Task {
                do {
                    let content = try await api.fetchChapter(comicId: comicId, index: target)
                    cacheChapter(content, for: target)
                    evictCache(keeping: center)
                } catch {
                    // 静默失败，不影响当前阅读
                }
            }
        }
    }

    /// 淘汰距离当前章节最远的缓存，保留最多 cacheCapacity 条
    private func evictCache(keeping center: Int) {
        guard chapterCache.count > cacheCapacity else { return }
        let sorted = chapterCache.keys.sorted { abs($0 - center) < abs($1 - center) }
        for key in sorted.dropFirst(cacheCapacity) {
            if let removed = chapterCache.removeValue(forKey: key) {
                chapterCacheBytes -= Self.chapterByteSize(removed)
            }
        }
        Self.totalNovelCacheBytes = chapterCacheBytes
    }

    /// 卷切换时清空缓存
    private func clearCache() {
        chapterCache.removeAll()
        chapterCacheBytes = 0
        Self.totalNovelCacheBytes = 0
    }

    /// 缓存一个章节并更新字节计数
    private func cacheChapter(_ content: ChapterContent, for index: Int) {
        if let old = chapterCache[index] {
            chapterCacheBytes -= Self.chapterByteSize(old)
        }
        chapterCache[index] = content
        chapterCacheBytes += Self.chapterByteSize(content)
        Self.totalNovelCacheBytes = chapterCacheBytes
    }

    /// 估算单个章节的内存占用
    private static func chapterByteSize(_ content: ChapterContent) -> Int {
        var size = 0
        if let title = content.title { size += title.utf8.count }
        if let text = content.content { size += text.utf8.count }
        return size
    }

    // MARK: - 加载

    func load(comicId: String, chapter: Int, fontSize: Double = 17, groupContext: ReadingGroupContext? = nil) async {
        self.comicId = comicId
        self.currentComicId = comicId
        self.groupContext = groupContext

        // 优先从缓存读取
        if applyFromCache(chapter: chapter, fontSize: fontSize) {
            preloadAdjacentChapters(fontSize: fontSize)
            return
        }

        // 缓存未命中，走网络
        self.currentChapter = chapter
        isLoading = true
        do {
            chapterContent = try await api.fetchChapter(comicId: comicId, index: chapter)
            if let content = chapterContent {
                cacheChapter(content, for: chapter)
            }
            // 更新章节数
            if let t = chapterContent?.totalChapters {
                totalChapters = t
            } else if totalChapters == 0 {
                // 服务端未返回 totalChapters，通过 fetchPages 获取
                if let pageList = try? await api.fetchPages(comicId: comicId) {
                    totalChapters = pageList.totalPages
                }
            }
            evictCache(keeping: chapter)
            repaginate(fontSize: fontSize)
        } catch {
            AppLogger.error("加载章节失败: \(error)")
        }
        isLoading = false

        preloadAdjacentChapters(fontSize: fontSize)
    }

    func loadVolume(comicId: String, chapter: Int, fontSize: Double = 17) async {
        // Update group context index
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
        clearCache()

        do {
            let pageList = try await api.fetchPages(comicId: comicId)
            // For novels, totalPages from the API represents total chapters
            self.totalChapters = max(1, pageList.totalPages)
            let safeChapter = min(chapter, self.totalChapters - 1)
            chapterContent = try await api.fetchChapter(comicId: comicId, index: safeChapter)
            if let content = chapterContent {
                cacheChapter(content, for: safeChapter)
            }
            currentChapter = safeChapter
            repaginate(fontSize: fontSize)
        } catch {
            AppLogger.error("加载卷失败: \(error)")
        }
        isLoading = false

        preloadAdjacentChapters(fontSize: fontSize)
    }

    func nextChapter(fontSize: Double = 17) async {
        let nextIndex = currentChapter + 1

        // 检查是否超出当前卷
        if totalChapters > 0 && nextIndex >= totalChapters {
            guard let nextId = groupContext?.nextVolumeId else { return }
            await loadVolume(comicId: nextId, chapter: 0, fontSize: fontSize)
            return
        }

        // 优先缓存
        if applyFromCache(chapter: nextIndex, fontSize: fontSize) {
            preloadAdjacentChapters(fontSize: fontSize)
            return
        }

        await load(comicId: comicId, chapter: nextIndex, fontSize: fontSize)
    }

    func prevChapter(fontSize: Double = 17) async {
        guard currentChapter > 0 else {
            // 第一章 — 尝试上一卷
            guard let prevId = groupContext?.previousVolumeId else { return }
            if let pageList = try? await api.fetchPages(comicId: prevId) {
                let lastChapter = max(0, pageList.totalPages - 1)
                await loadVolume(comicId: prevId, chapter: lastChapter, fontSize: fontSize)
            }
            return
        }

        let prevIndex = currentChapter - 1

        // 优先缓存
        if applyFromCache(chapter: prevIndex, fontSize: fontSize) {
            preloadAdjacentChapters(fontSize: fontSize)
            return
        }

        await load(comicId: comicId, chapter: prevIndex, fontSize: fontSize)
    }

    func saveProgress(currentPage: Int = 0) async {
        try? await api.updateProgress(comicId: currentComicId, page: currentChapter)
    }

    func repaginate(fontSize: Double) {
        let screen = UIScreen.main.bounds
        let safeAreaTop = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 0
        let maxW = screen.width - 40
        let maxH = screen.height - safeAreaTop - 40
        let titleHeight: CGFloat = (chapterContent?.title != nil) ? fontSize * 2.5 : 0
        let firstPageMaxH = maxH - titleHeight
        pages = paginate(text: plainText, fontSize: fontSize, maxWidth: maxW, maxHeight: maxH, firstPageMaxH: firstPageMaxH)
    }

    func paginate(text: String, fontSize: Double, maxWidth: CGFloat, maxHeight: CGFloat, firstPageMaxH: CGFloat? = nil) -> [String] {
        guard !text.isEmpty else { return [""] }

        let font = UIFont.systemFont(ofSize: fontSize)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = fontSize * 0.6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paraStyle]

        let label = UILabel()
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = maxWidth

        let fpMaxH = firstPageMaxH ?? maxHeight
        label.attributedText = NSAttributedString(string: text, attributes: attrs)
        if label.intrinsicContentSize.height <= fpMaxH { return [text] }

        var result: [String] = []
        var remaining = text
        var isFirstPage = true

        while !remaining.isEmpty {
            let pageMaxH = isFirstPage ? fpMaxH : maxHeight
            let pageText = findPageText(text: remaining, attrs: attrs, maxWidth: maxWidth, maxHeight: pageMaxH, label: label)
            result.append(pageText)
            let end = remaining.index(remaining.startIndex, offsetBy: pageText.count)
            remaining = String(remaining[end...])
            isFirstPage = false
        }

        return result
    }

    private func findPageText(text: String, attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat, maxHeight: CGFloat, label: UILabel) -> String {
        var low = 1
        var high = text.count
        var best = 1

        while low <= high {
            let mid = (low + high) / 2
            let end = text.index(text.startIndex, offsetBy: min(mid, text.count))
            label.attributedText = NSAttributedString(string: String(text[text.startIndex..<end]), attributes: attrs)
            if label.intrinsicContentSize.height <= maxHeight {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let end = text.index(text.startIndex, offsetBy: min(best, text.count))
        var pageText = String(text[text.startIndex..<end])

        if best < text.count {
            let searchStart = pageText.index(pageText.endIndex, offsetBy: -min(30, pageText.count))
            if let dot = pageText[searchStart..<pageText.endIndex].lastIndex(where: { "。！？.!?".contains($0) }) {
                pageText = String(pageText[pageText.startIndex...dot])
            }
        }

        return pageText
    }
}

// MARK: - Extensions
