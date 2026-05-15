import SwiftUI
import UIKit

// MARK: - 小说阅读器（SwiftUI 入口）

struct NovelReaderView: View {
    let comicId: String
    let initialChapter: Int

    @StateObject private var viewModel = NovelReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showOverlay = false
    @State private var fontSize: Double = UserDefaults.standard.double(forKey: "novel_font_size").clamped(to: 12...30, default: 17)
    @State private var currentPage = 0

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
                    },
                    onReachEnd: {
                        showOverlay = false
                        let saved = currentPage
                        Task {
                            await viewModel.saveProgress(currentPage: saved)
                            currentPage = 0
                            await viewModel.nextChapter(fontSize: fontSize)
                        }
                    },
                    onSwipeToPrev: {
                        showOverlay = false
                        let saved = currentPage
                        Task {
                            await viewModel.saveProgress(currentPage: saved)
                            currentPage = max(0, viewModel.pages.count - 1)
                            await viewModel.prevChapter(fontSize: fontSize)
                        }
                    }
                )
                .ignoresSafeArea()
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            let saved = UserDefaults.standard.integer(forKey: "novel_page_\(comicId)_\(initialChapter)")
            currentPage = saved
        }
        .task {
            await viewModel.load(comicId: comicId, chapter: initialChapter, fontSize: fontSize)
        }
        .onDisappear {
            Task { await viewModel.saveProgress(currentPage: currentPage) }
        }
        .onChange(of: fontSize) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "novel_font_size")
            viewModel.repaginate(fontSize: newValue)
        }
        .onTapGesture { showOverlay.toggle() }
        .overlay(alignment: .top) {
            if showOverlay { topOverlay }
        }
        .overlay(alignment: .bottom) {
            if showOverlay { bottomOverlay }
        }
    }

    private var backgroundForTheme: Color {
        viewModel.darkMode ? Color(white: 0.1) : Color(.systemBackground)
    }

    // MARK: - 顶部工具栏

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

    // MARK: - 底部工具栏

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
                    let saved = currentPage
                    Task {
                        await viewModel.saveProgress(currentPage: saved)
                        currentPage = max(0, viewModel.pages.count - 1)
                        await viewModel.prevChapter(fontSize: fontSize)
                    }
                } label: {
                    Label("上一章", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .disabled(viewModel.currentChapter <= 0)

                Spacer()

                if currentPage >= viewModel.pages.count - 1 {
                    Button {
                        showOverlay = false
                        let saved = currentPage
                        Task {
                            await viewModel.saveProgress(currentPage: saved)
                            currentPage = 0
                            await viewModel.nextChapter(fontSize: fontSize)
                        }
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
                        let saved = currentPage
                        Task {
                            await viewModel.saveProgress(currentPage: saved)
                            currentPage = 0
                            await viewModel.nextChapter(fontSize: fontSize)
                        }
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

        guard !pages.isEmpty else { return }

        let pagesChanged = coord.cachedVCs.count != pages.count
            || coord.cachedVCs.first?.pageText != pages.first
            || coord.cachedVCs.last?.pageText != pages.last

        if pagesChanged {
            coord.rebuildCache(pages: pages, fontSize: fontSize, darkMode: darkMode, title: chapterTitle)
            let page = min(initialPage, coord.cachedVCs.count - 1)
            if page >= 0, page < coord.cachedVCs.count {
                pvc.setViewControllers([coord.cachedVCs[page]], direction: .forward, animated: false)
                coord.currentIndex = page
            }
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let parent: NovelPager
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

        // DataSource
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

        // Delegate
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

// MARK: - ViewModel

@MainActor
final class NovelReaderViewModel: ObservableObject {
    @Published var chapterContent: ChapterContent?
    @Published var isLoading = false
    @Published var currentChapter = 0
    @Published var darkMode = false
    @Published var pages: [String] = []

    var plainText: String { chapterContent?.content ?? "" }

    private var comicId = ""
    private let api = APIClient.shared

    func load(comicId: String, chapter: Int, fontSize: Double = 17) async {
        self.comicId = comicId
        self.currentChapter = chapter
        isLoading = true
        do {
            chapterContent = try await api.fetchChapter(comicId: comicId, index: chapter)
            repaginate(fontSize: fontSize)
        } catch {
            print("加载章节失败: \(error)")
        }
        isLoading = false
    }

    func nextChapter(fontSize: Double = 17) async {
        await load(comicId: comicId, chapter: currentChapter + 1, fontSize: fontSize)
    }

    func prevChapter(fontSize: Double = 17) async {
        guard currentChapter > 0 else { return }
        await load(comicId: comicId, chapter: currentChapter - 1, fontSize: fontSize)
    }

    func saveProgress(currentPage: Int = 0) async {
        try? await api.updateProgress(comicId: comicId, page: currentChapter)
        UserDefaults.standard.set(currentPage, forKey: "novel_page_\(comicId)_\(currentChapter)")
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paraStyle,
        ]

        let label = UILabel()
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = maxWidth

        let fpMaxH = firstPageMaxH ?? maxHeight
        label.attributedText = NSAttributedString(string: text, attributes: attrs)
        if label.intrinsicContentSize.height <= fpMaxH {
            return [text]
        }

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
                pageText = String(pageText[pageText.startIndex..<pageText.index(after: dot)])
            }
        }

        return pageText
    }
}

// MARK: - Extensions

extension Comparable {
    func clamped(to range: ClosedRange<Self>, default defaultValue: Self) -> Self {
        range.contains(self) ? self : defaultValue
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
