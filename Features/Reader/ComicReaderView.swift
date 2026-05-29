import SwiftUI
import UIKit

// MARK: - 漫画阅读器（SwiftUI 入口）

struct ComicReaderView: View {
    let comicId: String
    let initialPage: Int
    var groupContext: ReadingGroupContext? = nil

    @StateObject private var viewModel = ComicReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                PageViewController(
                    comicId: viewModel.currentComicId,
                    totalPages: viewModel.totalPages,
                    currentPage: $viewModel.currentPage,
                    onToggleOverlay: { showOverlay.toggle() },
                    onPageChange: { page in
                        viewModel.onPageChanged(page)
                    },
                    onReachEnd: {
                        guard let nextId = viewModel.groupContext?.nextVolumeId else { return }
                        Task { await viewModel.loadVolume(comicId: nextId, initialPage: 0) }
                    },
                    onSwipeToPrev: {
                        guard let prevId = viewModel.groupContext?.previousVolumeId else { return }
                        Task {
                            // 先获取上一卷页数，跳到末尾
                            let pages = try? await APIClient.shared.fetchPages(comicId: prevId)
                            let lastPage = max(0, (pages?.totalPages ?? 1) - 1)
                            await viewModel.loadVolume(comicId: prevId, initialPage: lastPage)
                        }
                    }
                )
                .id(viewModel.currentComicId)
                .ignoresSafeArea()
            }

            // 工具栏覆盖层
            if showOverlay && !viewModel.isLoading {
                overlayUI
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showOverlay)
        .task {
            await viewModel.load(comicId: comicId, initialPage: initialPage, groupContext: groupContext)
        }
        .onDisappear {
            Task {
                await viewModel.saveProgressAndWait()
                await viewModel.endSessionAndWait()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task {
                    await viewModel.saveProgressAndWait()
                    await viewModel.endSessionAndWait()
                }
            }
        }
    }

    private var overlayUI: some View {
        VStack {
            // 顶部栏
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                }

                Spacer()

                Text("\(viewModel.currentPage + 1) / \(viewModel.totalPages)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)

                Spacer()

                if viewModel.groupContext != nil {
                    Text(volumeLabel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.trailing, 4)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            // 底部进度条
            VStack(spacing: 8) {
                Text("第 \(viewModel.currentPage + 1) 页")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.currentPage) },
                        set: { viewModel.onSliderChanged(Int($0)) }
                    ),
                    in: 0...Double(max(0, viewModel.totalPages - 1)),
                    step: 1
                )
                .tint(Color.accentColor)

                HStack {
                    Text("1")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(viewModel.totalPages)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
            .background(.ultraThinMaterial.opacity(0.3))
        }
        .transition(.opacity)
    }

    private var volumeLabel: String {
        guard let ctx = viewModel.groupContext else { return "" }
        return "\(ctx.currentIndex + 1)/\(ctx.volumeIds.count)"
    }
}

// MARK: - UIKit 翻页控制器（桥接）

struct PageViewController: UIViewControllerRepresentable {
    let comicId: String
    let totalPages: Int
    @Binding var currentPage: Int
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    func makeUIViewController(context: Context) -> PageViewControllerImpl {
        let vc = PageViewControllerImpl(
            comicId: comicId,
            totalPages: totalPages,
            currentPage: currentPage,
            onToggleOverlay: onToggleOverlay,
            onPageChange: { page in
                currentPage = page
                onPageChange(page)
            },
            onReachEnd: onReachEnd,
            onSwipeToPrev: onSwipeToPrev
        )
        return vc
    }

    func updateUIViewController(_ uiViewController: PageViewControllerImpl, context: Context) {
        uiViewController.totalPages = totalPages
        uiViewController.comicId = comicId
        uiViewController.onReachEnd = onReachEnd
        uiViewController.onSwipeToPrev = onSwipeToPrev
        uiViewController.goToPage(currentPage)
    }
}

// MARK: - UIPageViewController 实现

class PageViewControllerImpl: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var comicId: String
    var totalPages: Int
    var currentIdx: Int
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    init(
        comicId: String,
        totalPages: Int,
        currentPage: Int,
        onToggleOverlay: @escaping () -> Void,
        onPageChange: @escaping (Int) -> Void,
        onReachEnd: (() -> Void)?,
        onSwipeToPrev: (() -> Void)?
    ) {
        self.comicId = comicId
        self.totalPages = totalPages
        self.currentIdx = currentPage
        self.onToggleOverlay = onToggleOverlay
        self.onPageChange = onPageChange
        self.onReachEnd = onReachEnd
        self.onSwipeToPrev = onSwipeToPrev
        super.init(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
        self.dataSource = self
        self.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let initial = makePage(for: currentIdx) {
            setViewControllers([initial], direction: .forward, animated: false)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let width = view.bounds.width
        // 左右 1/3 区域翻页，中间 1/3 区域切换覆盖层
        if point.x < width / 3 {
            // 点击左侧：上一页
            guard currentIdx > 0 else {
                DispatchQueue.main.async { self.onSwipeToPrev?() }
                return
            }
            currentIdx -= 1
            if let vc = makePage(for: currentIdx) {
                setViewControllers([vc], direction: .reverse, animated: true)
                onPageChange(currentIdx)
            }
        } else if point.x > width * 2 / 3 {
            // 点击右侧：下一页
            guard currentIdx < totalPages - 1 else {
                DispatchQueue.main.async { self.onReachEnd?() }
                return
            }
            currentIdx += 1
            if let vc = makePage(for: currentIdx) {
                setViewControllers([vc], direction: .forward, animated: true)
                onPageChange(currentIdx)
            }
        } else {
            // 点击中间：切换覆盖层
            onToggleOverlay()
        }
    }

    func goToPage(_ page: Int) {
        guard viewIfLoaded != nil, page != currentIdx, page >= 0, page < totalPages else { return }
        let direction: NavigationDirection = page > currentIdx ? .forward : .reverse
        if let vc = makePage(for: page) {
            setViewControllers([vc], direction: direction, animated: true)
            currentIdx = page
        }
    }

    // MARK: - DataSource

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ZoomablePageVC else { return nil }
        let idx = vc.pageIndex - 1
        if idx < 0 {
            DispatchQueue.main.async { self.onSwipeToPrev?() }
            return nil
        }
        return makePage(for: idx)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let vc = viewController as? ZoomablePageVC else { return nil }
        let idx = vc.pageIndex + 1
        if idx >= totalPages {
            DispatchQueue.main.async { self.onReachEnd?() }
            return nil
        }
        return makePage(for: idx)
    }

    // MARK: - Delegate

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let vc = pvc.viewControllers?.first as? ZoomablePageVC else { return }
        currentIdx = vc.pageIndex
        onPageChange(vc.pageIndex)
    }

    // MARK: - Page Factory

    private func makePage(for index: Int) -> ZoomablePageVC? {
        guard let url = APIClient.shared.pageImageURL(comicId: comicId, page: index) else { return nil }
        return ZoomablePageVC(imageURL: url, pageIndex: index)
    }
}

// MARK: - 可缩放单页 VC

class ZoomablePageVC: UIViewController, UIScrollViewDelegate {
    let imageURL: URL
    let pageIndex: Int
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(imageURL: URL, pageIndex: Int) {
        self.imageURL = imageURL
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // ScrollView
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        // ImageView
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)

        // 双击缩放
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Loading
        activityIndicator.color = .white
        activityIndicator.center = view.center
        activityIndicator.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)

        loadImage()
    }

    private func loadImage() {
        var request = URLRequest(url: imageURL)
        if let cookies = HTTPCookieStorage.shared.cookies(for: imageURL) {
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.imageView.image = image
                self.fitImage()
            }
        }.resume()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitImage()
    }

    private func fitImage() {
        scrollView.frame = view.bounds
        scrollView.zoomScale = 1.0
        guard let image = imageView.image else {
            imageView.frame = scrollView.bounds
            return
        }
        let viewSize = scrollView.bounds.size
        let imageSize = image.size
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        imageView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        scrollView.contentSize = CGSize(width: w, height: h)
        updateInset()
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInset()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateInset()
    }

    private func updateInset() {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width * scrollView.zoomScale) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height * scrollView.zoomScale) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let rect = zoomRect(for: scrollView.maximumZoomScale, center: point)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    private func zoomRect(for scale: CGFloat, center: CGPoint) -> CGRect {
        let w = scrollView.bounds.width / scale
        let h = scrollView.bounds.height / scale
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
}

// MARK: - ViewModel

@MainActor
final class ComicReaderViewModel: ObservableObject {
    @Published var totalPages = 0
    @Published var currentPage = 0
    @Published var isLoading = true
    @Published var currentComicId: String
    @Published var groupContext: ReadingGroupContext?

    private var sessionId: Int?
    private var sessionStart: Date?
    private let api = APIClient.shared

    init() {
        self.currentComicId = ""
    }

    func load(comicId: String, initialPage: Int, groupContext: ReadingGroupContext? = nil) async {
        self.currentComicId = comicId
        self.groupContext = groupContext
        self.currentPage = initialPage
        do {
            let pages = try await api.fetchPages(comicId: comicId)
            totalPages = pages.totalPages
            isLoading = false
            startSession()
        } catch {
            AppLogger.error("加载页面列表失败: \(error)")
            isLoading = false
        }
    }

    func loadVolume(comicId: String, initialPage: Int) async {
        await saveProgressAndWait()
        await endSessionAndWait()
        isLoading = true

        // Update group context index
        if let ctx = groupContext,
           let newIdx = ctx.volumeIds.firstIndex(of: comicId) {
            groupContext = ReadingGroupContext(
                groupId: ctx.groupId,
                volumeIds: ctx.volumeIds,
                currentIndex: newIdx
            )
        }

        currentComicId = comicId
        currentPage = initialPage

        do {
            let pages = try await api.fetchPages(comicId: comicId)
            totalPages = pages.totalPages
            isLoading = false
            startSession()
        } catch {
            AppLogger.error("加载下一卷失败: \(error)")
            isLoading = false
        }
    }

    func onPageChanged(_ page: Int) {
        currentPage = page
        saveProgress()
    }

    func onSliderChanged(_ page: Int) {
        currentPage = page
    }

    private var saveTask: Task<Void, Never>?

    func saveProgress() {
        saveTask?.cancel()
        let page = currentPage
        let comicId = currentComicId
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            try? await api.updateProgress(comicId: comicId, page: page)
        }
    }

    /// 等待完成版本，退出时调用
    func saveProgressAndWait() async {
        saveTask?.cancel()
        try? await api.updateProgress(comicId: currentComicId, page: currentPage)
    }

    func endSessionAndWait() async {
        guard let sessionId, let sessionStart else { return }
        let duration = Int(Date().timeIntervalSince(sessionStart))
        try? await api.endSession(sessionId: sessionId, endPage: currentPage, duration: duration)
    }

    private func startSession() {
        Task {
            sessionId = try? await api.startSession(comicId: currentComicId, startPage: currentPage)
            sessionStart = Date()
        }
    }
}