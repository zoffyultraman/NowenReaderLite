import SwiftUI
import UIKit

import SwiftData

// MARK: - 漫画阅读器（SwiftUI 入口）

struct ComicReaderView: View {
    let comicId: String
    let initialPage: Int
    var groupContext: ReadingGroupContext? = nil

    @State private var viewModel = ComicReaderViewModel()
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showOverlay = false
    @AppStorage("pageTransitionStyle") private var pageTransitionStyle: String = "翻书"

    var body: some View {
        @Bindable var viewModel = viewModel
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
            } else if viewModel.totalPages <= 0 {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("无法加载页面")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button { dismiss() } label: {
                        Text("返回")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                GeometryReader { geometry in
                    let isLandscape = geometry.size.width > geometry.size.height
                    UnifiedComicPager(
                        comicId: viewModel.currentComicId,
                        totalPages: viewModel.totalPages,
                        currentPage: $viewModel.currentPage,
                        isDoublePageMode: isLandscape,
                        isRTL: UserDefaults.standard.bool(forKey: "isRTL"),
                        upscaleMode: upscaleMode,
                        onToggleOverlay: { withAnimation(.easeInOut) { showOverlay.toggle() } },
                        onPageChange: { page in viewModel.onPageChanged(page) },
                        onReachEnd: {
                            guard let nextId = viewModel.groupContext?.nextVolumeId else { return }
                            Task { await viewModel.loadVolume(comicId: nextId, initialPage: 0) }
                        },
                        onSwipeToPrev: {
                            guard let prevId = viewModel.groupContext?.previousVolumeId else { return }
                            Task {
                                let tp: Int
                                if let pages = try? await APIClient.shared.fetchPages(comicId: prevId) { tp = pages.totalPages }
                                else if let meta = OfflineFileManager.shared.loadMeta(comicId: prevId) { tp = meta.pageCount }
                                else { tp = 1 }
                                await viewModel.loadVolume(comicId: prevId, initialPage: max(0, tp - 1))
                            }
                        }
                    )
                    .id("\(viewModel.currentComicId)_\(isLandscape ? "double" : "single")")
                    .ignoresSafeArea()
                }
            }

            // 工具栏覆盖层
            if showOverlay && !viewModel.isLoading {
                overlayUI
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showOverlay)
        .task {
            viewModel.setModelContext(modelContext)
            await viewModel.load(comicId: comicId, initialPage: initialPage, groupContext: groupContext)
        }
        .onDisappear {
            Task {
                await viewModel.saveProgressAndWait()
                await viewModel.endSessionAndWait()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.resumeActivity()
            } else if newPhase == .background || newPhase == .inactive {
                viewModel.pauseActivity()
                Task {
                    await viewModel.saveProgressAndWait()
                }
            }
        }
    }

    // 轻量覆盖层：闭包每次 body 求值时重建，但视图简单，不会引起可见问题
    private var overlayUI: some View {
        ReaderOverlayView(
            currentPage: viewModel.currentPage,
            totalPages: viewModel.totalPages,
            sliderValue: $viewModel.sliderValue,
            hasGroupContext: viewModel.groupContext != nil,
            volumeLabel: volumeLabel,
            onDismiss: { dismiss() }
        )
    }

    private var volumeLabel: String {
        guard let ctx = viewModel.groupContext else { return "" }
        return "\(ctx.currentIndex + 1)/\(ctx.volumeIds.count)"
    }
}

// MARK: - 阅读器覆盖层
// 轻量视图：onDismiss 闭包每次 body 求值时重建，但视图简单，不会引起可见问题

struct ReaderOverlayView: View {
    let currentPage: Int
    let totalPages: Int
    @Binding var sliderValue: Double
    let hasGroupContext: Bool
    let volumeLabel: String
    let onDismiss: () -> Void

    @AppStorage("isRTL") private var isRTL: Bool = true
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                }

                Spacer()

                if hasGroupContext {
                    Text(volumeLabel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.trailing, 8)
                }

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.85), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )

            Spacer()

            // Bottom Toolbar
            HStack {
                Text("Page \(currentPage + 1) / \(totalPages)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)

                Spacer()

                Toggle(isOn: $isRTL) {
                    Text("RTL Mode")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                }
                .toggleStyle(.switch)
                .tint(.accentColor)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
        .transition(.opacity)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView()
        }
    }
}

// MARK: - 可缩放单页 VC

class ZoomablePageVC: UIViewController, UIScrollViewDelegate {
    let imageURL: URL
    let pageIndex: Int
    let comicId: String
    private let cachedImage: UIImage?
    var onImageLoaded: ((UIImage) -> Void)?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(imageURL: URL, pageIndex: Int, comicId: String, cachedImage: UIImage? = nil) {
        self.imageURL = imageURL
        self.pageIndex = pageIndex
        self.comicId = comicId
        self.cachedImage = cachedImage
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
        // 优先使用缓存图片
        if let cached = cachedImage {
            activityIndicator.stopAnimating()
            imageView.image = cached
            fitImage()
            return
        }

        // 离线优先：检查本地已下载文件
        if let localData = OfflineFileManager.shared.loadPageData(comicId: comicId, page: pageIndex) {
            if let image = UIImage(data: localData) {
                activityIndicator.stopAnimating()
                imageView.image = image
                fitImage()
                onImageLoaded?(image)
                return
            } else {
                AppLogger.log("本地图片解码失败: \(comicId) page \(pageIndex), 大小 \(localData.count) bytes")
            }
        }

        // 网络不可达时直接跳过，不等超时
        guard APIClient.shared.isNetworkReachable else {
            AppLogger.log("网络不可达，跳过网络加载: \(comicId) page \(pageIndex)")
            return
        }

        let request = APIClient.shared.authenticatedRequest(url: imageURL)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                AppLogger.log("页面加载失败: \(self.comicId) page \(self.pageIndex): \(error.localizedDescription)")
                return
            }
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.imageView.image = image
                self.fitImage()
                self.onImageLoaded?(image)
            }
        }.resume()
    }

    /// 更新图片（用于超分完成后替换）
    func updateImage(_ image: UIImage) {
        imageView.image = image
        fitImage()
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

// MARK: - 全局阅读器缓存
class ReaderCacheManager {
    static let shared = ReaderCacheManager()
    let imageCache = NSCache<NSString, UIImage>()
    let upscaledCache = NSCache<NSString, UIImage>()
    
    func clear() {
        imageCache.removeAllObjects()
        upscaledCache.removeAllObjects()
    }
}

// MARK: - 统一翻页控制器（SwiftUI 桥接）
struct UnifiedComicPager: UIViewControllerRepresentable {
    let comicId: String
    let totalPages: Int
    @Binding var currentPage: Int
    let isDoublePageMode: Bool
    let isRTL: Bool
    let upscaleMode: UpscaleMode
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    func makeUIViewController(context: Context) -> UnifiedComicPagerImpl {
        let vc = UnifiedComicPagerImpl(
            comicId: comicId,
            totalPages: totalPages,
            initialPage: currentPage,
            isDoublePageMode: isDoublePageMode,
            isRTL: isRTL,
            upscaleMode: upscaleMode
        )
        vc.onToggleOverlay = onToggleOverlay
        vc.onPageChange = { page in
            self.currentPage = page
            self.onPageChange(page)
        }
        vc.onReachEnd = onReachEnd
        vc.onSwipeToPrev = onSwipeToPrev
        return vc
    }

    func updateUIViewController(_ uiViewController: UnifiedComicPagerImpl, context: Context) {
        if uiViewController.basePageIndex != currentPage {
            uiViewController.goToPage(currentPage)
        }
        
        // Handle changes in mode and RTL
        var needsReload = false
        if uiViewController.isDoublePageMode != isDoublePageMode {
            uiViewController.isDoublePageMode = isDoublePageMode
            needsReload = true
        }
        if uiViewController.isRTL != isRTL {
            uiViewController.isRTL = isRTL
            needsReload = true
        }
        if uiViewController.upscaleMode != upscaleMode {
            uiViewController.upscaleMode = upscaleMode
            uiViewController.onUpscaleModeChanged()
        }
        
        if needsReload {
            uiViewController.reloadPages()
        }
    }
}

// MARK: - UIPageViewController 统一实现
class UnifiedComicPagerImpl: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let comicId: String
    let totalPages: Int
    var isDoublePageMode: Bool
    var isRTL: Bool
    var upscaleMode: UpscaleMode
    
    var onToggleOverlay: (() -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?
    
    var basePageIndex: Int = 0
    private var preloadingTasks: [Int: Task<Void, Never>] = [:]
    private var upscalingTasks: [Int: Task<Void, Never>] = [:]
    
    init(comicId: String, totalPages: Int, initialPage: Int, isDoublePageMode: Bool, isRTL: Bool, upscaleMode: UpscaleMode) {
        self.comicId = comicId
        self.totalPages = totalPages
        self.basePageIndex = initialPage
        self.isDoublePageMode = isDoublePageMode
        self.isRTL = isRTL
        self.upscaleMode = upscaleMode
        
        let spineLoc: UIPageViewController.SpineLocation = isDoublePageMode ? .mid : (isRTL ? .max : .min)
        super.init(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: [
            .spineLocation: NSNumber(value: spineLoc.rawValue)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    deinit {
        preloadingTasks.values.forEach { $0.cancel() }
        upscalingTasks.values.forEach { $0.cancel() }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.dataSource = self
        self.delegate = self
        self.view.backgroundColor = .black
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        self.view.addGestureRecognizer(tapGesture)
        
        // Initial Load
        reloadPages()
    }
    
    func goToPage(_ page: Int) {
        guard page >= 0, page < totalPages else { return }
        
        let targetBase = isDoublePageMode ? (page - (page % 2)) : page
        if targetBase == basePageIndex { return }
        
        // Calculate direction based on target page and RTL
        let isMovingForward = targetBase > basePageIndex
        let direction: UIPageViewController.NavigationDirection
        
        if isRTL {
            direction = isMovingForward ? .reverse : .forward
        } else {
            direction = isMovingForward ? .forward : .reverse
        }
        
        self.basePageIndex = targetBase
        let vcs = makePages(for: basePageIndex)
        
        setViewControllers(vcs, direction: direction, animated: true) { [weak self] _ in
            self?.notifyPageChange()
        }
        preloadPages(around: basePageIndex)
    }
    
    func reloadPages() {
        // Enforce even index for double page mode
        if isDoublePageMode && basePageIndex % 2 != 0 {
            basePageIndex -= 1
        }
        basePageIndex = max(0, min(basePageIndex, totalPages - 1))
        
        self.isDoubleSided = isDoublePageMode
        let vcs = makePages(for: basePageIndex)
        
        // We use .forward here as default for reloading inplace
        setViewControllers(vcs, direction: .forward, animated: false) { [weak self] _ in
            self?.notifyPageChange()
        }
        preloadPages(around: basePageIndex)
    }
    
    // MARK: - Spine Location (Dynamic switching)
    func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
        if isDoublePageMode {
            pageViewController.isDoubleSided = true
            return .mid
        } else {
            pageViewController.isDoubleSided = false
            return isRTL ? .max : .min
        }
    }
    
    // MARK: - Touch Handling
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let width = view.bounds.width
        
        if location.x < width * 0.3 {
            // Tapped Left
            if isRTL {
                // Next Page
                if isDoublePageMode {
                    if basePageIndex + 2 < totalPages { goToPage(basePageIndex + 2) }
                    else { onReachEnd?() }
                } else {
                    if basePageIndex + 1 < totalPages { goToPage(basePageIndex + 1) }
                    else { onReachEnd?() }
                }
            } else {
                // Prev Page
                if isDoublePageMode {
                    if basePageIndex - 2 >= 0 { goToPage(basePageIndex - 2) }
                    else { onSwipeToPrev?() }
                } else {
                    if basePageIndex - 1 >= 0 { goToPage(basePageIndex - 1) }
                    else { onSwipeToPrev?() }
                }
            }
        } else if location.x > width * 0.7 {
            // Tapped Right
            if isRTL {
                // Prev Page
                if isDoublePageMode {
                    if basePageIndex - 2 >= 0 { goToPage(basePageIndex - 2) }
                    else { onSwipeToPrev?() }
                } else {
                    if basePageIndex - 1 >= 0 { goToPage(basePageIndex - 1) }
                    else { onSwipeToPrev?() }
                }
            } else {
                // Next Page
                if isDoublePageMode {
                    if basePageIndex + 2 < totalPages { goToPage(basePageIndex + 2) }
                    else { onReachEnd?() }
                } else {
                    if basePageIndex + 1 < totalPages { goToPage(basePageIndex + 1) }
                    else { onReachEnd?() }
                }
            }
        } else {
            onToggleOverlay?()
        }
    }
    
    // MARK: - Delegate
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let currentVCs = pageViewController.viewControllers else { return }
        
        if isDoublePageMode {
            let leftVC = currentVCs.first
            let rightVC = currentVCs.last
            
            // In double page mode, RTL means rightVC is basePageIndex, leftVC is basePageIndex+1
            var computedBase = -1
            if let rVC = rightVC as? ZoomablePageVC, let lVC = leftVC as? ZoomablePageVC {
                computedBase = isRTL ? rVC.pageIndex : lVC.pageIndex
            } else if let rVC = rightVC as? ZoomablePageVC, leftVC is BlankPageVC {
                computedBase = rVC.pageIndex
            } else if let lVC = leftVC as? ZoomablePageVC, rightVC is BlankPageVC {
                computedBase = isRTL ? (lVC.pageIndex - 1) : lVC.pageIndex
            }
            
            if computedBase >= 0 {
                self.basePageIndex = computedBase - (computedBase % 2)
            }
        } else {
            if let vc = currentVCs.first as? ZoomablePageVC {
                self.basePageIndex = vc.pageIndex
            }
        }
        
        notifyPageChange()
        preloadPages(around: basePageIndex)
        
        // Show upscaled if ready
        if isDoublePageMode {
            checkAndShowUpscaledImage(for: basePageIndex)
            checkAndShowUpscaledImage(for: basePageIndex + 1)
        } else {
            checkAndShowUpscaledImage(for: basePageIndex)
        }
    }
    
    private func notifyPageChange() {
        onPageChange?(basePageIndex)
    }
    
    // MARK: - DataSource
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        let currentIndex: Int
        if let zvc = viewController as? ZoomablePageVC {
            currentIndex = zvc.pageIndex
        } else if let bvc = viewController as? BlankPageVC {
            currentIndex = bvc.pageIndex
        } else {
            return nil
        }
        
        let targetIndex = isRTL ? currentIndex + 1 : currentIndex - 1
        
        if isDoublePageMode {
            // In double page mode, we allow up to totalPages (which is the blank page index)
            // But only if the base page index of that spread would be valid.
            // Actually, an easier way is to allow targetIndex == totalPages if the OTHER page in the spread is totalPages - 1.
            let targetBase = targetIndex - (targetIndex % 2)
            if targetBase >= totalPages { return nil }
            if targetIndex < 0 { return nil }
            return makeSinglePage(for: targetIndex)
        } else {
            if targetIndex < 0 || targetIndex >= totalPages { return nil }
            return makeSinglePage(for: targetIndex)
        }
    }
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        let currentIndex: Int
        if let zvc = viewController as? ZoomablePageVC {
            currentIndex = zvc.pageIndex
        } else if let bvc = viewController as? BlankPageVC {
            currentIndex = bvc.pageIndex
        } else {
            return nil
        }
        
        let targetIndex = isRTL ? currentIndex - 1 : currentIndex + 1
        
        if isDoublePageMode {
            let targetBase = targetIndex - (targetIndex % 2)
            if targetBase >= totalPages { return nil }
            if targetIndex < 0 { return nil }
            return makeSinglePage(for: targetIndex)
        } else {
            if targetIndex < 0 || targetIndex >= totalPages { return nil }
            return makeSinglePage(for: targetIndex)
        }
    }
    
    // MARK: - Page Factory
    private func makePages(for index: Int) -> [UIViewController] {
        if isDoublePageMode {
            let base = index - (index % 2)
            let page1 = makeSinglePage(for: base)
            let page2 = makeSinglePage(for: base + 1)
            return isRTL ? [page2, page1] : [page1, page2]
        } else {
            return [makeSinglePage(for: index)]
        }
    }
    
    private func makeSinglePage(for index: Int) -> UIViewController {
        if index >= totalPages {
            return BlankPageVC(pageIndex: index)
        }
        guard let url = APIClient.shared.pageImageURL(comicId: comicId, page: index) else {
            AppLogger.log("无法创建页面 URL: \(comicId) page \(index)")
            return BlankPageVC(pageIndex: index)
        }
        
        let cached = ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: index))
        let upscaled = ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index))
        let vc = ZoomablePageVC(imageURL: url, pageIndex: index, comicId: comicId, cachedImage: upscaled ?? cached)
        vc.onImageLoaded = { [weak self] image in
            guard let self else { return }
            ReaderCacheManager.shared.imageCache.setObject(image, forKey: self.cacheKey(for: index))
            self.startUpscaleIfNeeded(for: index, image: image)
        }
        if let cachedImage = cached, upscaled == nil {
            startUpscaleIfNeeded(for: index, image: cachedImage)
        }
        return vc
    }
    
    // MARK: - Caching & Upscaling
    private func cacheKey(for index: Int) -> NSString {
        return "\(comicId)_page_\(index)" as NSString
    }
    
    private func upscaleTaskKey(for index: Int, mode: UpscaleMode) -> String {
        return "\(comicId)_\(index)_\(mode.rawValue)"
    }
    
    private func upscaledCacheKey(for index: Int) -> NSString {
        return "\(comicId)_upscaled_\(index)" as NSString
    }
    
    private func preloadPages(around currentIndex: Int) {
        let preloadRange = isDoublePageMode ? (currentIndex-4...currentIndex+5) : (currentIndex-2...currentIndex+2)
        for i in preloadRange {
            guard i >= 0 && i < totalPages else { continue }
            if ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: i)) == nil && preloadingTasks[i] == nil {
                let task = Task {
                    if Task.isCancelled { return }
                    if let _ = OfflineFileManager.shared.loadPageData(comicId: comicId, page: i) { return }
                    if let url = APIClient.shared.pageImageURL(comicId: comicId, page: i),
                       let data = try? await URLSession.shared.data(from: url).0,
                       let image = UIImage(data: data) {
                        if !Task.isCancelled {
                            ReaderCacheManager.shared.imageCache.setObject(image, forKey: cacheKey(for: i))
                        }
                    }
                    preloadingTasks[i] = nil
                }
                preloadingTasks[i] = task
            }
        }
    }
    
    private func startUpscaleIfNeeded(for index: Int, image: UIImage) {
        let mode = self.upscaleMode
        guard mode != .off else { return }
        let key = upscaledCacheKey(for: index)
        
        if ReaderCacheManager.shared.upscaledCache.object(forKey: key) != nil { return }
        
        // 检查是否已有任务在运行
        if let existingTask = upscalingTasks[index], !existingTask.isCancelled { return }
        
        let priority: TaskPriority = (index == basePageIndex || index == basePageIndex + 1) ? .high : .medium
        
        let task = Task { [weak self] in
            guard let self else { return }
            let shouldKeepOriginalSize = UserDefaults.standard.bool(forKey: "keepOriginalSize")
            
            do {
                // 使用 Task.detached 在后台执行，不继承 MainActor
                let result = try await Task.detached(priority: priority) {
                    try ImageUpscaler.shared.upscale(image, mode: mode, keepOriginalSize: shouldKeepOriginalSize)
                }.value
                
                if !Task.isCancelled {
                    ReaderCacheManager.shared.upscaledCache.setObject(result, forKey: key)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.checkAndShowUpscaledImage(for: index)
                    }
                }
            } catch {
                print(">>> Upscale failed for page \(index): \(error)")
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.upscalingTasks.removeValue(forKey: index)
            }
        }
        upscalingTasks[index] = task
    }
    
    
    func onUpscaleModeChanged() {
        ReaderCacheManager.shared.upscaledCache.removeAllObjects()
        upscalingTasks.values.forEach { $0.cancel() }
        upscalingTasks.removeAll()
        
        guard let viewControllers = self.viewControllers else { return }
        for vc in viewControllers {
            if let zvc = vc as? ZoomablePageVC {
                // Remove upscaled image currently showing
                if let cached = ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: zvc.pageIndex)) {
                    zvc.updateImage(cached)
                    startUpscaleIfNeeded(for: zvc.pageIndex, image: cached)
                }
            }
        }
    }

    private func checkAndShowUpscaledImage(for index: Int) {
        guard let upscaled = ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index)) else { return }
        guard let viewControllers = self.viewControllers else { return }
        
        for vc in viewControllers {
            if let zvc = vc as? ZoomablePageVC, zvc.pageIndex == index {
                zvc.updateImage(upscaled)
            }
        }
    }
}

// MARK: - 空白占位页 VC
class BlankPageVC: UIViewController {
    let pageIndex: Int
    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
        self.view.backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }
}
import SwiftUI

struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pageTransitionStyle") private var pageTransitionStyle: String = "翻书"
    @AppStorage("isRTL") private var isRTL: Bool = true
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("阅读设置")) {
                    Picker("翻页效果", selection: $pageTransitionStyle) {
                        Text("翻书").tag("翻书")
                        Text("平移").tag("平移")
                    }
                    .pickerStyle(.segmented)
                    
                    Toggle("从右向左阅读 (RTL)", isOn: $isRTL)
                    
                    Picker("超分辨率", selection: $upscaleMode) {
                        ForEach(UpscaleMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
