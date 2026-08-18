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
    @AppStorage("isRTL") private var isRTL: Bool = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showOverlay = false

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
                        isRTL: isRTL,
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
        .readerStatusBarHidden(!showOverlay)
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
            isRTL: $isRTL,
            onDismiss: { dismiss() }
        )
    }

    private var volumeLabel: String {
        guard let ctx = viewModel.groupContext else { return "" }
        return "卷 \(ctx.currentIndex + 1)/\(ctx.volumeIds.count)"
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
    @Binding var isRTL: Bool
    let onDismiss: () -> Void

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")

                Spacer()

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("阅读设置")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.black.opacity(0.72))

            Spacer()

            // Bottom Toolbar
            HStack {
                Text(positionLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)

                Spacer()

                Toggle(isOn: $isRTL) {
                    Text("从右向左翻页")
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
            .background(.black.opacity(0.72))
        }
        .transition(.opacity)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView()
        }
    }

    private var positionLabel: String {
        let page = "页 \(currentPage + 1)/\(totalPages)"
        guard hasGroupContext, !volumeLabel.isEmpty else { return page }
        return "\(volumeLabel) · \(page)"
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
    private var imageLoadTask: Task<Void, Never>?
    private var fittedBoundsSize = CGSize.zero
    private var hasFittedImage = false

    init(imageURL: URL, pageIndex: Int, comicId: String, cachedImage: UIImage? = nil) {
        self.imageURL = imageURL
        self.pageIndex = pageIndex
        self.comicId = comicId
        self.cachedImage = cachedImage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageLoadTask?.cancel()
    }

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

        imageLoadTask?.cancel()
        imageLoadTask = Task { [weak self] in
            guard let self else { return }
            guard let image = await ReaderCacheManager.shared.loadSourceImage(
                comicId: comicId,
                page: pageIndex,
                imageURL: imageURL
            ), !Task.isCancelled else { return }
            display(image)
        }
    }

    private func display(_ image: UIImage) {
        activityIndicator.stopAnimating()
        imageView.image = image
        fitImage()
        onImageLoaded?(image)
    }

    /// 更新图片（用于超分完成后替换）
    func updateImage(_ image: UIImage) {
        imageView.image = image
        fitImage(preservingViewport: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        guard imageView.image != nil else {
            imageView.frame = scrollView.bounds
            return
        }
        guard fittedBoundsSize != scrollView.bounds.size else { return }
        fitImage(preservingViewport: hasFittedImage)
    }

    private func fitImage(preservingViewport: Bool = false) {
        let previousZoomScale = scrollView.zoomScale
        let previousContentOffset = scrollView.contentOffset
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
        fittedBoundsSize = scrollView.bounds.size

        if preservingViewport {
            let zoomScale = min(
                max(previousZoomScale, scrollView.minimumZoomScale),
                scrollView.maximumZoomScale
            )
            scrollView.setZoomScale(zoomScale, animated: false)
            updateInset()
            scrollView.setContentOffset(
                clampedContentOffset(previousContentOffset),
                animated: false
            )
        }
        hasFittedImage = true
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
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

    private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        let minX = -scrollView.contentInset.left
        let minY = -scrollView.contentInset.top
        let maxX = max(
            minX,
            scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right
        )
        let maxY = max(
            minY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
        )
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
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
@MainActor
final class ReaderCacheManager {
    static let shared = ReaderCacheManager()
    let imageCache = NSCache<NSString, UIImage>()
    let upscaledCache = NSCache<NSString, UIImage>()
    private var sourceImageTasks: [String: (id: UUID, task: Task<UIImage?, Never>)] = [:]

    func loadSourceImage(comicId: String, page: Int, imageURL: URL) async -> UIImage? {
        let key = "\(comicId)_page_\(page)"
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        if let existing = sourceImageTasks[key] {
            return await existing.task.value
        }

        let taskID = UUID()
        let task = Task<UIImage?, Never> {
            if let image = await loadOfflinePageImage(comicId: comicId, page: page) {
                return image
            }
            guard !Task.isCancelled, APIClient.shared.isNetworkReachable else {
                return nil
            }
            let request = APIClient.shared.authenticatedRequest(url: imageURL)
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  !Task.isCancelled else {
                return nil
            }
            return await decodePageImage(data)
        }
        sourceImageTasks[key] = (taskID, task)

        let image = await task.value
        if sourceImageTasks[key]?.id == taskID {
            sourceImageTasks.removeValue(forKey: key)
            if let image {
                imageCache.setObject(image, forKey: key as NSString)
            }
        }
        return image
    }

    func clear() {
        sourceImageTasks.values.forEach { $0.task.cancel() }
        sourceImageTasks.removeAll()
        imageCache.removeAllObjects()
        upscaledCache.removeAllObjects()
    }
}

private actor ReaderUpscaleScheduler {
    static let shared = ReaderUpscaleScheduler()

    func upscale(
        _ image: UIImage,
        mode: UpscaleMode,
        keepOriginalSize: Bool
    ) throws -> UIImage {
        try Task.checkCancellation()
        return try ImageUpscaler.shared.upscale(
            image,
            mode: mode,
            keepOriginalSize: keepOriginalSize
        )
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
    private var preloadingTaskIDs: [Int: UUID] = [:]
    private var upscalingTaskIDs: [Int: UUID] = [:]
    private var upscaleTargetIndices: Set<Int> = []
    private var pendingUpscaleImages: [Int: UIImage] = [:]
    private var unavailableUpscaleIndices: Set<Int> = []
    private var activeUpscaleIndex: Int?
    
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
    
    private func upscaledCacheKey(for index: Int) -> NSString {
        return "\(comicId)_upscaled_\(index)" as NSString
    }
    
    private func preloadPages(around currentIndex: Int) {
        let preloadRange = isDoublePageMode ? (currentIndex-4...currentIndex+5) : (currentIndex-2...currentIndex+2)
        let upscaleRange = isDoublePageMode ? (currentIndex-2...currentIndex+3) : (currentIndex-1...currentIndex+3)
        let preloadIndices = Set(
            preloadRange.filter { (0..<totalPages).contains($0) }
        )
        let upscaleIndices = Set(
            upscaleRange.filter { (0..<totalPages).contains($0) }
        )
        let requestedIndices = preloadIndices.union(upscaleIndices)
        upscaleTargetIndices = upscaleIndices

        for index in Array(preloadingTasks.keys)
        where !requestedIndices.contains(index) {
            preloadingTaskIDs.removeValue(forKey: index)
            preloadingTasks.removeValue(forKey: index)?.cancel()
        }
        for index in Array(upscalingTasks.keys)
        where !upscaleIndices.contains(index) {
            // 保留任务标识，等待取消完成后由统一收尾逻辑释放 activeUpscaleIndex。
            upscalingTasks[index]?.cancel()
        }
        pendingUpscaleImages = pendingUpscaleImages.filter { upscaleIndices.contains($0.key) }
        unavailableUpscaleIndices.formIntersection(upscaleIndices)

        for i in orderedLoadIndices(
            around: currentIndex,
            requestedIndices: requestedIndices
        ) {
            let shouldUpscale = upscaleIndices.contains(i)

            if let cachedImage = ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: i)) {
                if shouldUpscale {
                    startUpscaleIfNeeded(for: i, image: cachedImage)
                }
                continue
            }

            if preloadingTasks[i] == nil {
                unavailableUpscaleIndices.remove(i)
                let taskID = UUID()
                let priority = loadPriority(
                    for: i,
                    currentIndex: currentIndex,
                    upscaleIndices: upscaleIndices
                )
                let task = Task(priority: priority) { [weak self] in
                    guard let self else { return }
                    defer {
                        Task { @MainActor [weak self] in
                            guard self?.preloadingTaskIDs[i] == taskID else { return }
                            self?.preloadingTaskIDs.removeValue(forKey: i)
                            self?.preloadingTasks.removeValue(forKey: i)
                        }
                    }
                    if Task.isCancelled { return }

                    let image: UIImage?
                    if let url = APIClient.shared.pageImageURL(comicId: comicId, page: i) {
                        image = await ReaderCacheManager.shared.loadSourceImage(
                            comicId: comicId,
                            page: i,
                            imageURL: url
                        )
                    } else {
                        image = nil
                    }

                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if let image {
                            ReaderCacheManager.shared.imageCache.setObject(image, forKey: self.cacheKey(for: i))
                            self.startUpscaleIfNeeded(for: i, image: image)
                        } else if self.upscaleTargetIndices.contains(i) {
                            self.unavailableUpscaleIndices.insert(i)
                            self.reprioritizeUpscaleWork()
                        }
                    }
                }
                preloadingTaskIDs[i] = taskID
                preloadingTasks[i] = task
            }
        }
        reprioritizeUpscaleWork()
    }

    private func orderedLoadIndices(
        around currentIndex: Int,
        requestedIndices: Set<Int>
    ) -> [Int] {
        let upscaleOffsets = isDoublePageMode
            ? [0, 1, 2, 3, -1, -2]
            : [0, 1, 2, 3, -1]
        var ordered = upscaleOffsets
            .map { currentIndex + $0 }
            .filter { requestedIndices.contains($0) }
        let scheduled = Set(ordered)

        ordered.append(contentsOf: requestedIndices
            .filter { $0 > currentIndex && !scheduled.contains($0) }
            .sorted())
        ordered.append(contentsOf: requestedIndices
            .filter { $0 < currentIndex && !scheduled.contains($0) }
            .sorted(by: >))
        return ordered
    }

    private func loadPriority(
        for index: Int,
        currentIndex: Int,
        upscaleIndices: Set<Int>
    ) -> TaskPriority {
        if index == currentIndex || index == currentIndex + 1 {
            return .high
        }
        return upscaleIndices.contains(index) ? .medium : .low
    }
    
    private func startUpscaleIfNeeded(for index: Int, image: UIImage) {
        guard upscaleMode != .off, upscaleTargetIndices.contains(index) else { return }
        guard ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index)) == nil else {
            return
        }
        pendingUpscaleImages[index] = image
        unavailableUpscaleIndices.remove(index)
        reprioritizeUpscaleWork()
    }

    private func reprioritizeUpscaleWork() {
        guard upscaleMode != .off else {
            activeUpscaleIndex.flatMap { upscalingTasks[$0] }?.cancel()
            return
        }

        let preferredIndex = nextUpscaleIndex()
        if let activeUpscaleIndex {
            if preferredIndex != activeUpscaleIndex {
                upscalingTasks[activeUpscaleIndex]?.cancel()
            }
            return
        }

        guard let preferredIndex else { return }
        guard let image = pendingUpscaleImages[preferredIndex]
                ?? ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: preferredIndex)) else {
            // 严格等待更高优先级页面的原图，避免后页抢先占用模型。
            return
        }

        beginUpscale(for: preferredIndex, image: image)
    }

    private func nextUpscaleIndex() -> Int? {
        for index in orderedUpscaleIndices(around: basePageIndex)
        where upscaleTargetIndices.contains(index) {
            if ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index)) != nil {
                continue
            }
            if unavailableUpscaleIndices.contains(index) {
                continue
            }
            return index
        }
        return nil
    }

    private func orderedUpscaleIndices(around currentIndex: Int) -> [Int] {
        let offsets = isDoublePageMode
            ? [0, 1, 2, 3, -1, -2]
            : [0, 1, 2, 3, -1]
        return offsets
            .map { currentIndex + $0 }
            .filter { (0..<totalPages).contains($0) }
    }

    private func beginUpscale(for index: Int, image: UIImage) {
        let mode = upscaleMode
        let key = upscaledCacheKey(for: index)
        let priority: TaskPriority = index == basePageIndex ? .high : .medium
        let taskID = UUID()
        activeUpscaleIndex = index
        let task = Task(priority: priority) { [weak self] in
            guard let self else { return }
            let shouldKeepOriginalSize = UserDefaults.standard.bool(forKey: "keepOriginalSize")
            var succeeded = false

            do {
                try Task.checkCancellation()
                let result = try await ReaderUpscaleScheduler.shared.upscale(
                    image,
                    mode: mode,
                    keepOriginalSize: shouldKeepOriginalSize
                )
                
                if !Task.isCancelled {
                    ReaderCacheManager.shared.upscaledCache.setObject(result, forKey: key)
                    succeeded = true
                    self.checkAndShowUpscaledImage(for: index)
                }
            } catch is CancellationError {
                // 翻页或切换模式时取消属于正常控制流。
            } catch {
                print(">>> Upscale failed for page \(index): \(error)")
            }

            if self.upscalingTaskIDs[index] == taskID {
                self.upscalingTaskIDs.removeValue(forKey: index)
                self.upscalingTasks.removeValue(forKey: index)
                if self.activeUpscaleIndex == index {
                    self.activeUpscaleIndex = nil
                }
                if succeeded {
                    self.pendingUpscaleImages.removeValue(forKey: index)
                } else if !Task.isCancelled {
                    self.unavailableUpscaleIndices.insert(index)
                }
                self.reprioritizeUpscaleWork()
            }
        }
        upscalingTaskIDs[index] = taskID
        upscalingTasks[index] = task
    }
    
    
    func onUpscaleModeChanged() {
        ReaderCacheManager.shared.upscaledCache.removeAllObjects()
        upscalingTasks.values.forEach { $0.cancel() }
        upscalingTasks.removeAll()
        upscalingTaskIDs.removeAll()
        pendingUpscaleImages.removeAll()
        unavailableUpscaleIndices.removeAll()
        activeUpscaleIndex = nil
        
        for vc in viewControllers ?? [] {
            if let zvc = vc as? ZoomablePageVC {
                // Remove upscaled image currently showing
                if let cached = ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: zvc.pageIndex)) {
                    zvc.updateImage(cached)
                }
            }
        }
        preloadPages(around: basePageIndex)
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

private func loadOfflinePageImage(comicId: String, page: Int) async -> UIImage? {
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
        guard !Task.isCancelled,
              let data = OfflineFileManager.shared.loadPageData(comicId: comicId, page: page),
              !Task.isCancelled else {
            return nil
        }
        return UIImage(data: data)
    }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

private func decodePageImage(_ data: Data) async -> UIImage? {
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
        guard !Task.isCancelled else { return nil }
        return UIImage(data: data)
    }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
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
    @AppStorage("isRTL") private var isRTL: Bool = true
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读设置") {
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
