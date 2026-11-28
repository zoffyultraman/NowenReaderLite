import SwiftUI
import UIKit

import SwiftData

enum ComicPageDisplayMode: String, Hashable {
    case fit
    case fill
    case stretch
}

// MARK: - 漫画阅读器（SwiftUI 入口）

struct ComicReaderView: View {
    let comicId: String
    let initialPage: Int
    var groupContext: ReadingGroupContext? = nil

    @State private var viewModel = ComicReaderViewModel()
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    @AppStorage("keepOriginalSize") private var keepOriginalSize: Bool = false
    @AppStorage("upscaleSkipMinDimension") private var upscaleSkipThreshold: UpscaleSkipThreshold = .p1600
    @AppStorage("isRTL") private var isRTL: Bool = true
    @AppStorage("comicPageDisplayMode") private var pageDisplayMode: ComicPageDisplayMode = .fit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showOverlay = false
    @State private var isApplyingCloudPreferences = false

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
                        .foregroundStyle(.white.opacity(0.5))
                    Text("无法加载页面")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))

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
                    let isDoublePage = geometry.size.width >= 520
                        && geometry.size.width > geometry.size.height
                    UnifiedComicPager(
                        comicId: viewModel.currentComicId,
                        totalPages: viewModel.totalPages,
                        currentPage: $viewModel.currentPage,
                        isDoublePageMode: isDoublePage,
                        isRTL: isRTL,
                        pageDisplayMode: pageDisplayMode,
                        upscaleMode: upscaleMode,
                        keepOriginalSize: keepOriginalSize,
                        upscaleSkipThreshold: upscaleSkipThreshold,
                        isOverlayPresented: showOverlay,
                        hasNextVolume: viewModel.groupContext?.nextVolumeId != nil,
                        hasPreviousVolume: viewModel.groupContext?.previousVolumeId != nil,
                        onToggleOverlay: { showOverlay.toggle() },
                        onPageChange: { page in viewModel.onPageChanged(page) },
                        onPageLoaded: { id, page in
                            viewModel.onPageLoaded(comicId: id, page: page)
                        },
                        onReachEnd: {
                            guard let nextId = viewModel.groupContext?.nextVolumeId else { return }
                            Task {
                                await viewModel.loadVolume(
                                    comicId: nextId,
                                    initialPage: 0,
                                    markCurrentVolumeFinished: true
                                )
                            }
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
                    .id("\(viewModel.currentComicId)_\(isDoublePage ? "double" : "single")")
                    .ignoresSafeArea()
                }
            }

            if let banner = viewModel.volumeTransitionBanner {
                VStack {
                    Spacer()
                    Text(banner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 28)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // 工具栏覆盖层
            ReaderOverlayView(
                isPresented: showOverlay || viewModel.isLoading || viewModel.totalPages <= 0,
                currentPage: viewModel.currentPage,
                totalPages: viewModel.totalPages,
                hasGroupContext: viewModel.groupContext != nil,
                volumeLabel: volumeLabel,
                isRTL: $isRTL,
                isCurrentPageBookmarked: viewModel.isCurrentPageBookmarked,
                isBookmarkBusy: viewModel.isBookmarkBusy,
                bookmarks: viewModel.bookmarks,
                preferenceScope: viewModel.preferenceScope,
                canUseSeriesScope: viewModel.canUseSeriesScope,
                hasComicOverride: viewModel.scopedPreferences?.comicOverride != nil,
                isPreferenceBusy: viewModel.isPreferenceBusy,
                onSeek: { viewModel.onSliderChanged($0) },
                onToggleBookmark: {
                    Task { await viewModel.toggleCurrentPageBookmark() }
                },
                onUpdateBookmark: { bookmark, name, note in
                    await viewModel.updateBookmark(bookmark, name: name, note: note)
                },
                onDeleteBookmark: { bookmark in
                    await viewModel.deleteBookmark(bookmark)
                },
                onSelectPreferenceScope: { scope in
                    await viewModel.switchPreferenceScope(
                        scope,
                        isRTL: isRTL,
                        pageDisplayMode: pageDisplayMode,
                        upscaleMode: upscaleMode
                    )
                },
                onResetOverride: {
                    await viewModel.resetCurrentComicOverride()
                },
                onDismiss: { dismiss() }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .readerStatusBarHidden(true)
        .task {
            let defaults = UserDefaults.standard
            if let previousFill = defaults.object(forKey: "comicFillScreen") as? Bool {
                pageDisplayMode = previousFill ? .stretch : .fit
                defaults.removeObject(forKey: "comicFillScreen")
            }
            viewModel.setModelContext(modelContext)
            if scenePhase == .active {
                viewModel.resumeActivity()
            } else {
                viewModel.pauseActivity()
            }
            await viewModel.load(comicId: comicId, initialPage: initialPage, groupContext: groupContext)
        }
        .onDisappear {
            viewModel.pauseActivity()
            ReaderCacheManager.shared.purgeCachedImages()
            ReaderUpscaleScheduler.shared.reset()
            Task {
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
        .onChange(of: viewModel.cloudPreferenceRevision) { _, _ in
            isApplyingCloudPreferences = true
            if let cloudRTL = viewModel.cloudResolvedIsRTL {
                isRTL = cloudRTL
            }
            if let cloudFit = viewModel.cloudResolvedFitMode {
                pageDisplayMode = cloudFit
            }
            if let cloudUpscale = viewModel.cloudResolvedUpscaleMode {
                upscaleMode = cloudUpscale
            }
            Task { @MainActor in
                isApplyingCloudPreferences = false
            }
        }
        .onChange(of: isRTL) { _, _ in
            guard !isApplyingCloudPreferences else { return }
            viewModel.scheduleSaveCloudPreferences(
                isRTL: isRTL,
                pageDisplayMode: pageDisplayMode,
                upscaleMode: upscaleMode
            )
        }
        .onChange(of: pageDisplayMode) { _, _ in
            guard !isApplyingCloudPreferences else { return }
            viewModel.scheduleSaveCloudPreferences(
                isRTL: isRTL,
                pageDisplayMode: pageDisplayMode,
                upscaleMode: upscaleMode
            )
        }
        .onChange(of: upscaleMode) { _, _ in
            guard !isApplyingCloudPreferences else { return }
            viewModel.scheduleSaveCloudPreferences(
                isRTL: isRTL,
                pageDisplayMode: pageDisplayMode,
                upscaleMode: upscaleMode
            )
        }
    }

    private var volumeLabel: String {
        guard let ctx = viewModel.groupContext else { return "" }
        return "卷 \(ctx.currentIndex + 1)/\(ctx.volumeIds.count)"
    }
}

// MARK: - 阅读器覆盖层
// 轻量视图：onDismiss 闭包每次 body 求值时重建，但视图简单，不会引起可见问题

struct ReaderOverlayView: View {
    let isPresented: Bool
    let currentPage: Int
    let totalPages: Int
    let hasGroupContext: Bool
    let volumeLabel: String
    @Binding var isRTL: Bool
    let isCurrentPageBookmarked: Bool
    let isBookmarkBusy: Bool
    let bookmarks: [UserBookmark]
    let preferenceScope: ComicPreferenceScope
    let canUseSeriesScope: Bool
    let hasComicOverride: Bool
    let isPreferenceBusy: Bool
    let onSeek: (Int) -> Void
    let onToggleBookmark: () -> Void
    let onUpdateBookmark: (UserBookmark, String, String) async -> Void
    let onDeleteBookmark: (UserBookmark) async -> Void
    let onSelectPreferenceScope: (ComicPreferenceScope) async -> Void
    let onResetOverride: () async -> Void
    let onDismiss: () -> Void

    @State private var showSettings = false
    @State private var showBookmarks = false

    var body: some View {
        ReaderChrome(isPresented: isPresented) {
            HStack(spacing: 4) {
                ReaderBackButton(action: onDismiss)

                Spacer()

                Button(action: onToggleBookmark) {
                    Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isCurrentPageBookmarked ? Color.yellow : Color.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isCurrentPageBookmarked ? "取消当前页书签" : "添加当前页书签")
                .disabled(totalPages <= 0 || isBookmarkBusy)

                Button(action: { showBookmarks = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)

                        if !bookmarks.isEmpty {
                            Text("\(bookmarks.count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.yellow, in: Capsule())
                                .offset(x: -2, y: 4)
                        }
                    }
                }
                .accessibilityLabel("书签列表（\(bookmarks.count)）")
                .disabled(totalPages <= 0)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("阅读设置")
                .disabled(totalPages <= 0)
            }
        } footer: {
            if totalPages > 0 {
                ComicReaderProgressControls(
                    currentPage: currentPage, totalPages: totalPages,
                    volumeLabel: hasGroupContext ? volumeLabel : "",
                    isRTL: $isRTL, onSeek: onSeek
                )
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(
                preferenceScope: preferenceScope,
                canUseSeriesScope: canUseSeriesScope,
                hasComicOverride: hasComicOverride,
                isPreferenceBusy: isPreferenceBusy,
                onSelectPreferenceScope: onSelectPreferenceScope,
                onResetOverride: onResetOverride
            )
        }
        .sheet(isPresented: $showBookmarks) {
            ComicBookmarksSheet(
                currentPage: currentPage,
                bookmarks: bookmarks,
                isCurrentPageBookmarked: isCurrentPageBookmarked,
                isBookmarkBusy: isBookmarkBusy,
                onToggleCurrentPageBookmark: onToggleBookmark,
                onSelectPage: { page in
                    showBookmarks = false
                    onSeek(page)
                },
                onUpdateBookmark: onUpdateBookmark,
                onDeleteBookmark: onDeleteBookmark
            )
        }
    }
}

private struct ComicReaderProgressControls: View {
    let currentPage: Int
    let totalPages: Int
    let volumeLabel: String
    @Binding var isRTL: Bool
    let onSeek: (Int) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var draftPage: Double = 0
    @State private var isSeeking = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(positionLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Toggle(isOn: $isRTL) {
                    Text(horizontalSizeClass == .compact ? "右→左" : "从右向左翻页")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("从右向左翻页")
                .toggleStyle(.switch)
                .tint(.accentColor)
                .fixedSize()
            }
            Slider(
                value: $draftPage,
                in: 0...Double(max(totalPages - 1, 1)),
                step: 1,
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing { commitSeek() }
                }
            )
            .disabled(totalPages < 2)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .accessibilityLabel("阅读进度")
            .accessibilityValue("第 \(Int(draftPage) + 1) 页，共 \(totalPages) 页")
        }
        .onAppear { draftPage = Double(currentPage) }
        .onChange(of: currentPage) { _, page in
            if !isSeeking { draftPage = Double(page) }
        }
        .onChange(of: totalPages) { _, _ in
            isSeeking = false
            draftPage = Double(min(max(currentPage, 0), max(totalPages - 1, 0)))
        }
        .onChange(of: draftPage) { _, _ in
            // VoiceOver 调整滑块不会经过触摸拖动的开始/结束回调。
            if !isSeeking { commitSeek() }
        }
    }

    private func commitSeek() {
        let page = min(max(Int(draftPage), 0), max(totalPages - 1, 0))
        if page != currentPage { onSeek(page) }
    }

    private var positionLabel: String {
        let page = "页 \(Int(draftPage) + 1)/\(totalPages)"
        guard !volumeLabel.isEmpty else { return page }
        return "\(volumeLabel) · \(page)"
    }
}

// MARK: - 可缩放单页 VC

class ZoomablePageVC: UIViewController, UIScrollViewDelegate {
    let imageURL: URL
    let pageIndex: Int
    let comicId: String
    private let pageDisplayMode: ComicPageDisplayMode
    private let cachedImage: UIImage?
    private(set) var isDisplayingUpscaledImage: Bool
    var onImageLoaded: ((UIImage, Bool) -> Void)?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var imageLoadTask: Task<Void, Never>?
    private var fittedBoundsSize = CGSize.zero
    private var hasFittedImage = false

    init(
        imageURL: URL,
        pageIndex: Int,
        comicId: String,
        pageDisplayMode: ComicPageDisplayMode,
        cachedImage: UIImage? = nil,
        isCachedImageUpscaled: Bool = false
    ) {
        self.imageURL = imageURL
        self.pageIndex = pageIndex
        self.comicId = comicId
        self.pageDisplayMode = pageDisplayMode
        self.cachedImage = cachedImage
        self.isDisplayingUpscaledImage = isCachedImageUpscaled
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
        scrollView.clipsToBounds = true
        view.addSubview(scrollView)

        // ImageView
        imageView.contentMode = pageDisplayMode == .stretch ? .scaleToFill : .scaleAspectFit
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

        retryButton.setTitle("页面加载失败，点击重试", for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.frame = CGRect(x: 0, y: 0, width: 260, height: 48)
        retryButton.center = view.center
        retryButton.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        retryButton.isHidden = true
        view.addSubview(retryButton)

        loadImage()
    }

    private func loadImage() {
        // 优先使用缓存图片
        if let cached = cachedImage {
            activityIndicator.stopAnimating()
            imageView.image = cached
            fitImage()
            onImageLoaded?(cached, false)
            return
        }

        imageLoadTask?.cancel()
        imageLoadTask = Task { [weak self] in
            guard let self else { return }
            let image = await ReaderCacheManager.shared.loadSourceImage(
                comicId: comicId,
                page: pageIndex,
                imageURL: imageURL
            )
            guard !Task.isCancelled else { return }
            guard let image else {
                activityIndicator.stopAnimating()
                retryButton.isHidden = false
                return
            }
            display(image)
        }
    }

    @objc private func retryImage() {
        retryButton.isHidden = true
        activityIndicator.startAnimating()
        loadImage()
    }

    private func display(_ image: UIImage) {
        activityIndicator.stopAnimating()
        imageView.image = image
        fitImage()
        onImageLoaded?(image, true)
    }

    /// 更新图片（用于超分完成后替换或切换回原图）
    func updateImage(_ image: UIImage, isUpscaled: Bool = true) {
        isDisplayingUpscaledImage = isUpscaled
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
        let previousContentSize = scrollView.contentSize
        var viewportAnchor = CGPoint(x: 0.5, y: 0.5)
        if preservingViewport,
           previousContentSize.width > 0,
           previousContentSize.height > 0 {
            viewportAnchor = CGPoint(
                x: (previousContentOffset.x + fittedBoundsSize.width / 2)
                    / previousContentSize.width,
                y: (previousContentOffset.y + fittedBoundsSize.height / 2)
                    / previousContentSize.height
            )
        }
        scrollView.frame = view.bounds
        scrollView.zoomScale = 1.0
        guard let image = imageView.image else {
            imageView.frame = scrollView.bounds
            return
        }
        let viewSize = scrollView.bounds.size
        let imageSize = image.size
        guard viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }
        let widthScale = viewSize.width / imageSize.width
        let heightScale = viewSize.height / imageSize.height
        let scale = pageDisplayMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let contentSize = pageDisplayMode == .stretch
            ? viewSize
            : CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        updateInset()
        fittedBoundsSize = scrollView.bounds.size

        if preservingViewport {
            let zoomScale = min(
                max(previousZoomScale, scrollView.minimumZoomScale),
                scrollView.maximumZoomScale
            )
            scrollView.setZoomScale(zoomScale, animated: false)
            updateInset()
        }
        scrollView.setContentOffset(
            clampedContentOffset(CGPoint(
                x: viewportAnchor.x * scrollView.contentSize.width - viewSize.width / 2,
                y: viewportAnchor.y * scrollView.contentSize.height - viewSize.height / 2
            )),
            animated: false
        )
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
    private let imageBudget = 80 * 1024 * 1024
    private let upscaledBudget: Int
    let isHighMemoryDevice: Bool
    private var sourceImageTasks: [String: (id: UUID, task: Task<UIImage?, Never>, forDisplay: Bool, waiters: Int)] = [:]
    private var cacheGeneration = 0
    private var memoryWarningObserver: NSObjectProtocol?

    var maxSingleUpscaledPageBytes: Int {
        upscaledBudget / 4
    }

    private init() {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        isHighMemoryDevice = physicalMemory >= 5_500_000_000
        let upscaledCountLimit: Int
        if isHighMemoryDevice {
            upscaledBudget = 256 * 1024 * 1024
            upscaledCountLimit = 6
        } else if physicalMemory >= 3_500_000_000 {
            upscaledBudget = 192 * 1024 * 1024
            upscaledCountLimit = 5
        } else {
            upscaledBudget = 128 * 1024 * 1024
            upscaledCountLimit = 4
        }

        imageCache.countLimit = 12
        imageCache.totalCostLimit = imageBudget
        upscaledCache.countLimit = upscaledCountLimit
        upscaledCache.totalCostLimit = upscaledBudget
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clear()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    @discardableResult
    func storeImage(_ image: UIImage, forKey key: NSString) -> Bool {
        let cost = Self.decodedCost(of: image)
        guard cost <= imageBudget else { return false }
        imageCache.setObject(image, forKey: key, cost: cost)
        return true
    }

    @discardableResult
    func storeUpscaledImage(_ image: UIImage, forKey key: NSString) -> Bool {
        let cost = Self.decodedCost(of: image)
        guard cost <= upscaledBudget else { return false }
        upscaledCache.setObject(image, forKey: key, cost: cost)
        return true
    }

    private static func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(
                by: cgImage.height
            )
            return overflow ? Int.max : max(1, cost)
        }
        let cost = Double(image.size.width * image.scale)
            * Double(image.size.height * image.scale) * 4
        guard cost.isFinite, cost < Double(Int.max) else { return Int.max }
        return max(1, Int(cost))
    }

    func loadSourceImage(
        comicId: String,
        page: Int,
        imageURL: URL,
        forDisplay: Bool = true
    ) async -> UIImage? {
        let key = "\(comicId)_page_\(page)"
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        let taskID: UUID
        let task: Task<UIImage?, Never>
        let generation = cacheGeneration
        if var existing = sourceImageTasks[key] {
            if forDisplay {
                existing.forDisplay = true
            }
            existing.waiters += 1
            sourceImageTasks[key] = existing
            taskID = existing.id
            task = existing.task
        } else {
            taskID = UUID()
            let newTask = Task<UIImage?, Never> {
                if let image = await loadOfflinePageImage(comicId: comicId, page: page) {
                    return image
                }
                guard !Task.isCancelled, APIClient.shared.isNetworkReachable else {
                    return nil
                }
                guard let data = try? await APIClient.shared.authenticatedData(from: imageURL),
                      !Task.isCancelled else {
                    return nil
                }
                return await decodePageImage(data)
            }
            sourceImageTasks[key] = (taskID, newTask, forDisplay, 1)
            task = newTask
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, var entry = self.sourceImageTasks[key], entry.id == taskID else { return }
                entry.waiters -= 1
                if entry.waiters <= 0 && !entry.forDisplay {
                    self.sourceImageTasks.removeValue(forKey: key)
                    entry.task.cancel()
                } else {
                    self.sourceImageTasks[key] = entry
                }
            }
        }
        if sourceImageTasks[key]?.id == taskID {
            sourceImageTasks.removeValue(forKey: key)
            if let image, !task.isCancelled, generation == cacheGeneration {
                storeImage(image, forKey: key as NSString)
            }
        }
        return Task.isCancelled || task.isCancelled ? nil : image
    }

    func clear() {
        for key in Array(sourceImageTasks.keys) {
            guard let load = sourceImageTasks[key], !load.forDisplay else { continue }
            load.task.cancel()
            sourceImageTasks.removeValue(forKey: key)
        }
        purgeCachedImages()
    }

    func purgeCachedImages() {
        cacheGeneration &+= 1
        imageCache.removeAllObjects()
        upscaledCache.removeAllObjects()
    }
}

private final class UpscaleCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class ReaderUpscaleScheduler: @unchecked Sendable {
    static let shared = ReaderUpscaleScheduler()
    private let queue = DispatchQueue(
        label: "com.nowen.readerlite.upscaler",
        qos: .userInitiated
    )

    func upscale(
        _ image: UIImage,
        mode: UpscaleMode,
        keepOriginalSize: Bool,
        maxOutputBytes: Int,
        skipThreshold: UpscaleSkipThreshold
    ) async throws -> UIImage {
        try Task.checkCancellation()
        let token = UpscaleCancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        if token.isCancelled { throw CancellationError() }
                        let result = try ImageUpscaler.shared.upscale(
                            image,
                            mode: mode,
                            keepOriginalSize: keepOriginalSize,
                            maxOutputBytes: maxOutputBytes,
                            skipThreshold: skipThreshold,
                            isCancelled: { token.isCancelled }
                        )
                        if token.isCancelled { throw CancellationError() }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    func reset() {
        queue.async {
            ImageUpscaler.shared.reset()
        }
    }
}

// MARK: - 统一翻页控制器（SwiftUI 桥接）
struct UnifiedComicPager: UIViewControllerRepresentable {
    let comicId: String
    let totalPages: Int
    @Binding var currentPage: Int
    let isDoublePageMode: Bool
    let isRTL: Bool
    let pageDisplayMode: ComicPageDisplayMode
    let upscaleMode: UpscaleMode
    let keepOriginalSize: Bool
    let upscaleSkipThreshold: UpscaleSkipThreshold
    let isOverlayPresented: Bool
    let hasNextVolume: Bool
    let hasPreviousVolume: Bool
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    let onPageLoaded: (String, Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    func makeUIViewController(context: Context) -> UnifiedComicPagerImpl {
        let vc = UnifiedComicPagerImpl(
            comicId: comicId,
            totalPages: totalPages,
            initialPage: currentPage,
            isDoublePageMode: isDoublePageMode,
            isRTL: isRTL,
            pageDisplayMode: pageDisplayMode,
            upscaleMode: upscaleMode,
            keepOriginalSize: keepOriginalSize,
            upscaleSkipThreshold: upscaleSkipThreshold
        )
        vc.onToggleOverlay = onToggleOverlay
        vc.isOverlayPresented = isOverlayPresented
        vc.hasNextVolume = hasNextVolume
        vc.hasPreviousVolume = hasPreviousVolume
        vc.onPageChange = { page in
            self.currentPage = page
            self.onPageChange(page)
        }
        vc.onPageLoaded = { page in
            Task { @MainActor in self.onPageLoaded(self.comicId, page) }
        }
        vc.onReachEnd = onReachEnd
        vc.onSwipeToPrev = onSwipeToPrev
        return vc
    }

    func updateUIViewController(_ uiViewController: UnifiedComicPagerImpl, context: Context) {
        uiViewController.isOverlayPresented = isOverlayPresented
        uiViewController.hasNextVolume = hasNextVolume
        uiViewController.hasPreviousVolume = hasPreviousVolume
        uiViewController.onReachEnd = onReachEnd
        uiViewController.onSwipeToPrev = onSwipeToPrev
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
        if uiViewController.pageDisplayMode != pageDisplayMode {
            uiViewController.pageDisplayMode = pageDisplayMode
            needsReload = true
        }
        if uiViewController.upscaleMode != upscaleMode
            || uiViewController.keepOriginalSize != keepOriginalSize
            || uiViewController.upscaleSkipThreshold != upscaleSkipThreshold {
            uiViewController.upscaleMode = upscaleMode
            uiViewController.keepOriginalSize = keepOriginalSize
            uiViewController.upscaleSkipThreshold = upscaleSkipThreshold
            uiViewController.onUpscaleModeChanged()
        }
        
        if needsReload {
            uiViewController.reloadPages()
        }
    }

    static func dismantleUIViewController(_ uiViewController: UnifiedComicPagerImpl, coordinator: Void) {
        uiViewController.cancelBackgroundWork()
        uiViewController.onPageChange = nil
        uiViewController.onPageLoaded = nil
        uiViewController.onToggleOverlay = nil
        uiViewController.onReachEnd = nil
        uiViewController.onSwipeToPrev = nil
    }
}

// MARK: - UIPageViewController 统一实现
class UnifiedComicPagerImpl: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var isOverlayPresented = false
    var hasNextVolume = false
    var hasPreviousVolume = false
    let comicId: String
    let totalPages: Int
    var isDoublePageMode: Bool
    var isRTL: Bool
    var pageDisplayMode: ComicPageDisplayMode
    var upscaleMode: UpscaleMode
    var keepOriginalSize: Bool
    var upscaleSkipThreshold: UpscaleSkipThreshold
    
    var onToggleOverlay: (() -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onPageLoaded: ((Int) -> Void)?
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?
    
    var basePageIndex: Int = 0
    private var tapGesture: UITapGestureRecognizer?
    private var isVolumeTransitionPending = false
    private var readingDirection: Int = 1
    private var preloadingTasks: [Int: Task<Void, Never>] = [:]
    private var upscalingTasks: [Int: Task<Void, Never>] = [:]
    private var preloadingTaskIDs: [Int: UUID] = [:]
    private var upscalingTaskIDs: [Int: UUID] = [:]
    private var upscaleTargetIndices: Set<Int> = []
    private var completedUpscaleIndices: Set<Int> = []
    private var pendingUpscaleImages: [Int: UIImage] = [:]
    private var unavailableUpscaleIndices: Set<Int> = []
    private var activeUpscaleIndex: Int?
    private var lastMemoryWarningAt: ContinuousClock.Instant?
    private var lastPageTurnAt: ContinuousClock.Instant?
    private var upscaleResumeAt: ContinuousClock.Instant?
    private var upscaleDebounceTask: Task<Void, Never>?

    private var hasReceivedMemoryWarning: Bool {
        guard let lastMemoryWarningAt else { return false }
        return lastMemoryWarningAt.duration(to: .now) < .seconds(20)
    }
    
    init(
        comicId: String,
        totalPages: Int,
        initialPage: Int,
        isDoublePageMode: Bool,
        isRTL: Bool,
        pageDisplayMode: ComicPageDisplayMode,
        upscaleMode: UpscaleMode,
        keepOriginalSize: Bool,
        upscaleSkipThreshold: UpscaleSkipThreshold
    ) {
        self.comicId = comicId
        self.totalPages = totalPages
        self.basePageIndex = initialPage
        self.isDoublePageMode = isDoublePageMode
        self.isRTL = isRTL
        self.pageDisplayMode = pageDisplayMode
        self.upscaleMode = upscaleMode
        self.keepOriginalSize = keepOriginalSize
        self.upscaleSkipThreshold = upscaleSkipThreshold
        
        let spineLoc: UIPageViewController.SpineLocation = isDoublePageMode ? .mid : (isRTL ? .max : .min)
        super.init(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: [
            .spineLocation: NSNumber(value: spineLoc.rawValue)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    deinit {
        upscaleDebounceTask?.cancel()
        preloadingTasks.values.forEach { $0.cancel() }
        upscalingTasks.values.forEach { $0.cancel() }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.dataSource = self
        self.delegate = self
        self.view.backgroundColor = .black

        // 禁用 UIPageViewController 内置单击手势，确保左右边缘点击始终走自定义翻页与自动切卷逻辑。
        disableBuiltInPageTapGestures()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        self.tapGesture = tap
        self.view.addGestureRecognizer(tap)
        
        // Initial Load
        reloadPages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disableBuiltInPageTapGestures()
    }

    private func disableBuiltInPageTapGestures() {
        for recognizer in view.gestureRecognizers ?? []
        where recognizer is UITapGestureRecognizer && recognizer !== tapGesture {
            recognizer.isEnabled = false
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let view = touchedView {
            if view is UIControl { return false }
            touchedView = view.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === tapGesture,
              let otherTap = otherGestureRecognizer as? UITapGestureRecognizer else {
            return false
        }
        return otherTap.numberOfTapsRequired > 1
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        lastMemoryWarningAt = .now
        cancelBackgroundWork()
        ReaderCacheManager.shared.clear()
    }

    func cancelBackgroundWork() {
        upscaleDebounceTask?.cancel()
        upscaleDebounceTask = nil
        upscaleResumeAt = nil
        preloadingTasks.values.forEach { $0.cancel() }
        upscalingTasks.values.forEach { $0.cancel() }
        preloadingTasks.removeAll()
        upscalingTasks.removeAll()
        preloadingTaskIDs.removeAll()
        upscalingTaskIDs.removeAll()
        upscaleTargetIndices.removeAll()
        completedUpscaleIndices.removeAll()
        pendingUpscaleImages.removeAll()
        unavailableUpscaleIndices.removeAll()
        activeUpscaleIndex = nil
    }
    
    func goToPage(_ page: Int) {
        guard page >= 0, page < totalPages else { return }
        
        let targetBase = isDoublePageMode ? (page - (page % 2)) : page
        if targetBase == basePageIndex { return }
        
        // Calculate direction based on target page and RTL
        let isMovingForward = targetBase > basePageIndex
        readingDirection = isMovingForward ? 1 : -1
        recordPageTurn()
        let direction: UIPageViewController.NavigationDirection
        
        if isRTL {
            direction = isMovingForward ? .reverse : .forward
        } else {
            direction = isMovingForward ? .forward : .reverse
        }
        
        self.basePageIndex = targetBase
        completedUpscaleIndices.removeAll()
        let vcs = makePages(for: basePageIndex)

        setViewControllers(vcs, direction: direction, animated: true) { [weak self] _ in
            guard let self else { return }
            self.notifyPageChange()
            self.showUpscaledForVisiblePages()
        }
        preloadPages(around: basePageIndex)
    }

    func reloadPages() {
        isVolumeTransitionPending = false
        completedUpscaleIndices.removeAll()
        // Enforce even index for double page mode
        if isDoublePageMode && basePageIndex % 2 != 0 {
            basePageIndex -= 1
        }
        basePageIndex = max(0, min(basePageIndex, totalPages - 1))

        self.isDoubleSided = isDoublePageMode
        let vcs = makePages(for: basePageIndex)

        // We use .forward here as default for reloading inplace
        setViewControllers(vcs, direction: .forward, animated: false) { [weak self] _ in
            guard let self else { return }
            self.notifyPageChange()
            self.showUpscaledForVisiblePages()
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
    private func triggerReachEndIfNeeded() {
        guard hasNextVolume, !isVolumeTransitionPending else { return }
        isVolumeTransitionPending = true
        DispatchQueue.main.async { [weak self] in
            self?.onReachEnd?()
        }
    }

    private func triggerSwipeToPrevIfNeeded() {
        guard hasPreviousVolume, !isVolumeTransitionPending else { return }
        isVolumeTransitionPending = true
        DispatchQueue.main.async { [weak self] in
            self?.onSwipeToPrev?()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if isOverlayPresented {
            onToggleOverlay?()
            return
        }
        let location = gesture.location(in: view)
        let width = view.bounds.width
        
        if location.x < width * 0.3 {
            // Tapped Left
            if isRTL {
                // Next Page
                if isDoublePageMode {
                    if basePageIndex + 2 < totalPages { goToPage(basePageIndex + 2) }
                    else { triggerReachEndIfNeeded() }
                } else {
                    if basePageIndex + 1 < totalPages { goToPage(basePageIndex + 1) }
                    else { triggerReachEndIfNeeded() }
                }
            } else {
                // Prev Page
                if isDoublePageMode {
                    if basePageIndex - 2 >= 0 { goToPage(basePageIndex - 2) }
                    else { triggerSwipeToPrevIfNeeded() }
                } else {
                    if basePageIndex - 1 >= 0 { goToPage(basePageIndex - 1) }
                    else { triggerSwipeToPrevIfNeeded() }
                }
            }
        } else if location.x > width * 0.7 {
            // Tapped Right
            if isRTL {
                // Prev Page
                if isDoublePageMode {
                    if basePageIndex - 2 >= 0 { goToPage(basePageIndex - 2) }
                    else { triggerSwipeToPrevIfNeeded() }
                } else {
                    if basePageIndex - 1 >= 0 { goToPage(basePageIndex - 1) }
                    else { triggerSwipeToPrevIfNeeded() }
                }
            } else {
                // Next Page
                if isDoublePageMode {
                    if basePageIndex + 2 < totalPages { goToPage(basePageIndex + 2) }
                    else { triggerReachEndIfNeeded() }
                } else {
                    if basePageIndex + 1 < totalPages { goToPage(basePageIndex + 1) }
                    else { triggerReachEndIfNeeded() }
                }
            }
        } else {
            onToggleOverlay?()
        }
    }
    
    // MARK: - Delegate
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let currentVCs = pageViewController.viewControllers else { return }
        let previousBase = basePageIndex
        
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
        
        let delta = basePageIndex - previousBase
        if delta != 0 {
            readingDirection = delta > 0 ? 1 : -1
            recordPageTurn()
        }
        completedUpscaleIndices.removeAll()
        notifyPageChange()
        preloadPages(around: basePageIndex)
        showUpscaledForVisiblePages()
    }
    
    private func notifyPageChange() {
        onPageChange?(basePageIndex)
        if ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: basePageIndex)) != nil {
            onPageLoaded?(basePageIndex)
        }
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
            if targetBase >= totalPages {
                triggerReachEndIfNeeded()
                return nil
            }
            if targetIndex < 0 {
                triggerSwipeToPrevIfNeeded()
                return nil
            }
            return makeSinglePage(for: targetIndex)
        } else {
            if targetIndex >= totalPages {
                triggerReachEndIfNeeded()
                return nil
            }
            if targetIndex < 0 {
                triggerSwipeToPrevIfNeeded()
                return nil
            }
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
            if targetBase >= totalPages {
                triggerReachEndIfNeeded()
                return nil
            }
            if targetIndex < 0 {
                triggerSwipeToPrevIfNeeded()
                return nil
            }
            return makeSinglePage(for: targetIndex)
        } else {
            if targetIndex >= totalPages {
                triggerReachEndIfNeeded()
                return nil
            }
            if targetIndex < 0 {
                triggerSwipeToPrevIfNeeded()
                return nil
            }
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
        let vc = ZoomablePageVC(
            imageURL: url,
            pageIndex: index,
            comicId: comicId,
            pageDisplayMode: pageDisplayMode,
            cachedImage: upscaled ?? cached,
            isCachedImageUpscaled: upscaled != nil
        )
        vc.onImageLoaded = { [weak self] image, isFreshSource in
            guard let self else { return }
            if isFreshSource {
                ReaderCacheManager.shared.storeImage(image, forKey: self.cacheKey(for: index))
                self.startUpscaleIfNeeded(for: index, image: image)
            }
            if index == self.basePageIndex { self.onPageLoaded?(index) }
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
    
    private func recordPageTurn() {
        let now = ContinuousClock.now
        let isRapidFlip = lastPageTurnAt.map { $0.duration(to: now) < .milliseconds(450) } ?? false
        lastPageTurnAt = now
        upscaleDebounceTask?.cancel()
        upscaleDebounceTask = nil
        if isRapidFlip {
            let resumeAt = now.advanced(by: .milliseconds(160))
            upscaleResumeAt = resumeAt
            upscaleDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard let self, !Task.isCancelled else { return }
                self.upscaleResumeAt = nil
                self.upscaleDebounceTask = nil
                self.reprioritizeUpscaleWork()
            }
        } else {
            upscaleResumeAt = nil
        }
    }

    private func preloadPages(around currentIndex: Int) {
        let visibleRange = currentIndex...(currentIndex + (isDoublePageMode ? 1 : 0))
        let preloadRange: ClosedRange<Int>
        let upscaleRange: ClosedRange<Int>
        let singlePageUpscaleLookahead = (ReaderCacheManager.shared.isHighMemoryDevice || keepOriginalSize) ? 3 : 2
        if hasReceivedMemoryWarning {
            preloadRange = visibleRange
            upscaleRange = visibleRange
        } else if readingDirection >= 0 {
            if isDoublePageMode {
                preloadRange = (currentIndex - 2)...(currentIndex + 3)
                upscaleRange = currentIndex...(currentIndex + 3)
            } else {
                preloadRange = (currentIndex - 1)...(currentIndex + singlePageUpscaleLookahead + 1)
                upscaleRange = currentIndex...(currentIndex + singlePageUpscaleLookahead)
            }
        } else {
            if isDoublePageMode {
                preloadRange = (currentIndex - 4)...(currentIndex + 1)
                upscaleRange = (currentIndex - 2)...(currentIndex + 1)
            } else {
                preloadRange = (currentIndex - singlePageUpscaleLookahead - 1)...(currentIndex + 1)
                upscaleRange = (currentIndex - singlePageUpscaleLookahead)...currentIndex
            }
        }
        let preloadIndices = Set(
            preloadRange.filter { (0..<totalPages).contains($0) }
        )
        let upscaleIndices: Set<Int> = upscaleMode == .off
            ? []
            : Set(upscaleRange.filter { (0..<totalPages).contains($0) })
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
        completedUpscaleIndices.formIntersection(upscaleIndices)
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
                            imageURL: url,
                            forDisplay: false
                        )
                    } else {
                        image = nil
                    }

                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if let image {
                            ReaderCacheManager.shared.storeImage(image, forKey: self.cacheKey(for: i))
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
        let offsets: [Int]
        if readingDirection >= 0 {
            offsets = isDoublePageMode ? [0, 1, 2, 3, -1, -2] : [0, 1, 2, 3, -1]
        } else {
            offsets = isDoublePageMode ? [0, 1, -1, -2, -3, -4] : [0, -1, -2, -3, 1]
        }
        var ordered = offsets
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
        let immediateNextIndex = isDoublePageMode
            ? (readingDirection >= 0 ? currentIndex + 2 : currentIndex - 1)
            : (currentIndex + readingDirection)
        if index == currentIndex
            || (isDoublePageMode && index == currentIndex + 1)
            || index == immediateNextIndex {
            return .high
        }
        return upscaleIndices.contains(index) ? .medium : .low
    }
    
    private func startUpscaleIfNeeded(for index: Int, image: UIImage) {
        guard upscaleMode != .off, upscaleTargetIndices.contains(index) else { return }
        if ImageUpscaler.shouldSkipUpscale(for: image, skipThreshold: upscaleSkipThreshold) {
            completedUpscaleIndices.insert(index)
            pendingUpscaleImages.removeValue(forKey: index)
            reprioritizeUpscaleWork()
            return
        }
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
        if let resumeAt = upscaleResumeAt {
            if ContinuousClock.now < resumeAt {
                return
            }
            upscaleResumeAt = nil
        }
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
            if ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index)) != nil
                || isDisplayingUpscaled(at: index)
                || completedUpscaleIndices.contains(index)
                || unavailableUpscaleIndices.contains(index) {
                continue
            }
            return index
        }
        return nil
    }

    private func isDisplayingUpscaled(at index: Int) -> Bool {
        (viewControllers ?? []).contains {
            guard let zvc = $0 as? ZoomablePageVC else { return false }
            return zvc.pageIndex == index && zvc.isDisplayingUpscaledImage
        }
    }

    private func showUpscaledForVisiblePages() {
        if isDoublePageMode {
            checkAndShowUpscaledImage(for: basePageIndex)
            checkAndShowUpscaledImage(for: basePageIndex + 1)
        } else {
            checkAndShowUpscaledImage(for: basePageIndex)
        }
    }

    private func orderedUpscaleIndices(around currentIndex: Int) -> [Int] {
        let offsets: [Int]
        if readingDirection >= 0 {
            offsets = isDoublePageMode ? [0, 1, 2, 3, -1, -2] : [0, 1, 2, 3, -1]
        } else {
            offsets = isDoublePageMode ? [0, 1, -1, -2, -3, -4] : [0, -1, -2, -3, 1]
        }
        return offsets
            .map { currentIndex + $0 }
            .filter { (0..<totalPages).contains($0) }
    }

    private func beginUpscale(for index: Int, image: UIImage) {
        let mode = upscaleMode
        let skipThreshold = upscaleSkipThreshold
        if ImageUpscaler.shouldSkipUpscale(for: image, skipThreshold: skipThreshold) {
            completedUpscaleIndices.insert(index)
            pendingUpscaleImages.removeValue(forKey: index)
            reprioritizeUpscaleWork()
            return
        }
        let shouldKeepOriginalSize = keepOriginalSize
        let key = upscaledCacheKey(for: index)
        let priority: TaskPriority = index == basePageIndex ? .high : .medium
        let maxOutputBytes = ReaderCacheManager.shared.maxSingleUpscaledPageBytes
        let taskID = UUID()
        activeUpscaleIndex = index
        let task = Task(priority: priority) { [weak self] in
            guard let self else { return }
            var succeeded = false

            do {
                try Task.checkCancellation()
                let result = try await ReaderUpscaleScheduler.shared.upscale(
                    image,
                    mode: mode,
                    keepOriginalSize: shouldKeepOriginalSize,
                    maxOutputBytes: maxOutputBytes,
                    skipThreshold: skipThreshold
                )
                
                if !Task.isCancelled {
                    let cached = ReaderCacheManager.shared.storeUpscaledImage(result, forKey: key)
                    succeeded = true
                    self.showUpscaledImage(result, for: index)
                    if !cached {
                        self.unavailableUpscaleIndices.insert(index)
                    }
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
                    self.completedUpscaleIndices.insert(index)
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
        upscaleDebounceTask?.cancel()
        upscaleDebounceTask = nil
        upscaleResumeAt = nil
        ReaderCacheManager.shared.upscaledCache.removeAllObjects()
        upscalingTasks.values.forEach { $0.cancel() }
        upscalingTasks.removeAll()
        upscalingTaskIDs.removeAll()
        completedUpscaleIndices.removeAll()
        pendingUpscaleImages.removeAll()
        unavailableUpscaleIndices.removeAll()
        activeUpscaleIndex = nil
        if upscaleMode == .off {
            ReaderUpscaleScheduler.shared.reset()
        }
        
        for vc in viewControllers ?? [] {
            if let zvc = vc as? ZoomablePageVC {
                // Remove upscaled image currently showing
                if let cached = ReaderCacheManager.shared.imageCache.object(forKey: cacheKey(for: zvc.pageIndex)) {
                    zvc.updateImage(cached, isUpscaled: false)
                }
            }
        }
        preloadPages(around: basePageIndex)
    }

    private func checkAndShowUpscaledImage(for index: Int) {
        guard let upscaled = ReaderCacheManager.shared.upscaledCache.object(forKey: upscaledCacheKey(for: index)) else { return }
        showUpscaledImage(upscaled, for: index)
    }

    private func showUpscaledImage(_ image: UIImage, for index: Int) {
        for vc in viewControllers ?? [] {
            if let zvc = vc as? ZoomablePageVC, zvc.pageIndex == index {
                zvc.updateImage(image)
            }
        }
    }
}

private func loadOfflinePageImage(comicId: String, page: Int) async -> UIImage? {
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
        guard !Task.isCancelled,
              let data = OfflineFileManager.shared.loadPageData(comicId: comicId, page: page),
              !Task.isCancelled,
              let img = UIImage(data: data) else {
            return nil
        }
        return img.preparingForDisplay() ?? img
    }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

private func decodePageImage(_ data: Data) async -> UIImage? {
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
        guard !Task.isCancelled, let img = UIImage(data: data) else { return nil }
        return img.preparingForDisplay() ?? img
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
    let preferenceScope: ComicPreferenceScope
    let canUseSeriesScope: Bool
    let hasComicOverride: Bool
    let isPreferenceBusy: Bool
    let onSelectPreferenceScope: (ComicPreferenceScope) async -> Void
    let onResetOverride: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("isRTL") private var isRTL: Bool = true
    @AppStorage("comicPageDisplayMode") private var pageDisplayMode: ComicPageDisplayMode = .fit
    @AppStorage("upscaleMode") private var upscaleMode: UpscaleMode = .off
    @AppStorage("upscaleSkipMinDimension") private var upscaleSkipThreshold: UpscaleSkipThreshold = .p1600
    @State private var selectedScope: ComicPreferenceScope = .global

    private var availableScopes: [ComicPreferenceScope] {
        canUseSeriesScope ? [.global, .series, .comic] : [.global, .comic]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("同步作用域", selection: $selectedScope) {
                        ForEach(availableScopes) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .disabled(isPreferenceBusy)
                    .onAppear {
                        selectedScope = preferenceScope
                    }
                    .onChange(of: preferenceScope) { _, newValue in
                        if selectedScope != newValue {
                            selectedScope = newValue
                        }
                    }
                    .onChange(of: selectedScope) { _, newValue in
                        guard newValue != preferenceScope else { return }
                        Task { await onSelectPreferenceScope(newValue) }
                    }

                    if hasComicOverride {
                        Button("恢复全局默认（清除本作品覆盖）", role: .destructive) {
                            Task { await onResetOverride() }
                        }
                        .disabled(isPreferenceBusy)
                    }
                } header: {
                    HStack {
                        Text("云端偏好同步")
                        if isPreferenceBusy {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } footer: {
                    switch preferenceScope {
                    case .global:
                        Text("使用全局默认设置（global_comic），修改将同步到所有漫画。")
                    case .series:
                        Text("仅为当前系列保存独立的阅读方向与画面适配方式（series）。")
                    case .comic:
                        Text("仅为当前作品覆盖阅读方向与画面适配方式（comic）；切回全局将移除作品覆盖。")
                    }
                }

                Section {
                    Picker("页面显示", selection: $pageDisplayMode) {
                        Text("完整显示").tag(ComicPageDisplayMode.fit)
                        Text("等比填充").tag(ComicPageDisplayMode.fill)
                        Text("拉伸铺满").tag(ComicPageDisplayMode.stretch)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("页面显示")
                } footer: {
                    switch pageDisplayMode {
                    case .fit:
                        Text("保持原比例，完整显示页面。")
                    case .fill:
                        Text("保持原比例铺满屏幕，页面边缘可能被裁切。")
                    case .stretch:
                        Text("完整铺满屏幕，画面比例会随屏幕调整。")
                    }
                }

                Section("阅读设置") {
                    Toggle("从右向左阅读 (RTL)", isOn: $isRTL)

                    Picker("超分辨率", selection: $upscaleMode) {
                        ForEach(UpscaleMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    if upscaleMode != .off {
                        Picker("高清原图跳过", selection: $upscaleSkipThreshold) {
                            ForEach(UpscaleSkipThreshold.allCases) { threshold in
                                Text(threshold.menuTitle).tag(threshold)
                            }
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

// MARK: - 漫画书签抽屉

struct ComicBookmarksSheet: View {
    let currentPage: Int
    let bookmarks: [UserBookmark]
    let isCurrentPageBookmarked: Bool
    let isBookmarkBusy: Bool
    let onToggleCurrentPageBookmark: () -> Void
    let onSelectPage: (Int) -> Void
    let onUpdateBookmark: (UserBookmark, String, String) async -> Void
    let onDeleteBookmark: (UserBookmark) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingBookmark: UserBookmark?

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "暂无书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击右上角书签按钮可保存当前页")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            ComicBookmarkRow(
                                bookmark: bookmark,
                                isCurrentPage: bookmark.pageIndex == currentPage,
                                onSelect: { onSelectPage(bookmark.pageIndex) },
                                onEdit: { editingBookmark = bookmark }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await onDeleteBookmark(bookmark) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingBookmark = bookmark
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("漫画书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onToggleCurrentPageBookmark()
                    } label: {
                        Label(
                            isCurrentPageBookmarked ? "移除当前页" : "书签当前页",
                            systemImage: isCurrentPageBookmarked ? "bookmark.slash" : "bookmark.fill"
                        )
                    }
                    .disabled(isBookmarkBusy)
                }
            }
            .sheet(item: $editingBookmark) { bookmark in
                BookmarkEditorSheet(
                    title: "编辑书签（第 \(bookmark.pageIndex + 1) 页）",
                    initialName: bookmark.name,
                    initialNote: bookmark.note
                ) { name, note in
                    await onUpdateBookmark(bookmark, name, note)
                }
            }
        }
    }
}

private struct ComicBookmarkRow: View {
    let bookmark: UserBookmark
    let isCurrentPage: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Text("P.\(bookmark.pageIndex + 1)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(isCurrentPage ? .black : .accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isCurrentPage ? Color.yellow : Color.accentColor.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 6)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.name.isEmpty ? "第 \(bookmark.pageIndex + 1) 页" : bookmark.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !bookmark.note.isEmpty {
                            Text(bookmark.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑书签")
        }
    }
}

struct BookmarkEditorSheet: View {
    let title: String
    let initialName: String
    let initialNote: String
    let onSave: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var note: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("书签名称", text: $name)
                }
                Section("备注") {
                    TextField("添加备注（可选）", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            await onSave(name, note)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                name = initialName
                note = initialNote
            }
        }
    }
}
