import SwiftUI
import UIKit
import SwiftData

// MARK: - 漫画阅读器（SwiftUI 入口）

struct ComicReaderView: View {
    let comicId: String
    let initialPage: Int
    var groupContext: ReadingGroupContext? = nil

    @StateObject private var viewModel = ComicReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showOverlay = false
    @AppStorage("pageTransitionStyle") private var pageTransitionStyle: String = "翻书"

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
                    transitionStyle: pageTransitionStyle,
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
                .id("\(viewModel.currentComicId)_\(pageTransitionStyle)")
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
    let transitionStyle: String
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    func makeUIViewController(context: Context) -> PageViewControllerImpl {
        let style: UIPageViewController.TransitionStyle = transitionStyle == "平移" ? .scroll : .pageCurl
        let vc = PageViewControllerImpl(
            comicId: comicId,
            totalPages: totalPages,
            currentPage: currentPage,
            transitionStyle: style,
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

@MainActor
class PageViewControllerImpl: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var comicId: String
    var totalPages: Int
    var currentIdx: Int
    let onToggleOverlay: () -> Void
    let onPageChange: (Int) -> Void
    var onReachEnd: (() -> Void)?
    var onSwipeToPrev: (() -> Void)?

    /// 页面图片内存缓存（限制 10 页，避免长时间阅读内存暴涨）
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 10
        return cache
    }()
    /// 超分结果缓存（限制 10 页，避免频繁淘汰）
    private let upscaledCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 10
        return cache
    }()
    /// 当前正在预加载的任务
    private var preloadTasks: [Int: Task<Void, Never>] = [:]
    /// 当前正在超分的任务（key: "page_mode"）
    private var upscaleTasks: [String: Task<Void, Never>] = [:]

    /// 缓存的超分设置（避免频繁读取 UserDefaults）
    private var _cachedUpscaleMode: UpscaleMode?
    private var _cachedKeepOriginalSize: Bool?

    /// 超分设置
    private var upscaleMode: UpscaleMode {
        if let cached = _cachedUpscaleMode { return cached }
        let mode: UpscaleMode
        if let stored = UserDefaults.standard.string(forKey: "upscaleMode"),
           let m = UpscaleMode(rawValue: stored) {
            mode = m
        } else {
            mode = .off
        }
        _cachedUpscaleMode = mode
        return mode
    }

    private var keepOriginalSize: Bool {
        if let cached = _cachedKeepOriginalSize { return cached }
        let value = UserDefaults.standard.bool(forKey: "keepOriginalSize")
        _cachedKeepOriginalSize = value
        return value
    }

    init(
        comicId: String,
        totalPages: Int,
        currentPage: Int,
        transitionStyle: UIPageViewController.TransitionStyle = .pageCurl,
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
        super.init(transitionStyle: transitionStyle, navigationOrientation: .horizontal, options: nil)
        self.dataSource = self
        self.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        preloadTasks.values.forEach { $0.cancel() }
        upscaleTasks.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let initial = makePage(for: currentIdx) {
            setViewControllers([initial], direction: .forward, animated: false)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // ✅ 监听 UserDefaults 变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // ✅ 首次进入时预加载周围页面
        preloadPages(around: currentIdx)
    }

    // ✅ 内存压力处理
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        // 取消所有后台任务
        preloadTasks.values.forEach { $0.cancel() }
        preloadTasks.removeAll()

        upscaleTasks.values.forEach { $0.cancel() }
        upscaleTasks.removeAll()

        // 保留当前页，清理其他缓存
        let currentKey = cacheKey(for: currentIdx)
        let currentUpscaledKey = upscaledCacheKey(for: currentIdx)

        // 临时保存当前页
        let currentImage = imageCache.object(forKey: currentKey)
        let currentUpscaled = upscaledCache.object(forKey: currentUpscaledKey)

        // 清空缓存
        imageCache.removeAllObjects()
        upscaledCache.removeAllObjects()

        // 恢复当前页
        if let image = currentImage {
            imageCache.setObject(image, forKey: currentKey)
        }
        if let upscaled = currentUpscaled {
            upscaledCache.setObject(upscaled, forKey: currentUpscaledKey)
        }
    }

    @objc private func userDefaultsDidChange() {
        // ✅ 清除缓存，下次访问时会重新读取
        _cachedUpscaleMode = nil
        _cachedKeepOriginalSize = nil
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
                preloadPages(around: currentIdx)
                checkAndShowUpscaledImage(for: currentIdx)
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
                preloadPages(around: currentIdx)
                checkAndShowUpscaledImage(for: currentIdx)
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
            onPageChange(page)
            preloadPages(around: page)

            // ✅ 跳页后，立即检查是否有超分结果可以显示（移除 0.1 秒延迟）
            checkAndShowUpscaledImage(for: page)
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
        preloadPages(around: vc.pageIndex)

        // ✅ 翻页完成后，检查是否有超分结果可以显示
        checkAndShowUpscaledImage(for: vc.pageIndex)
    }

    // MARK: - Page Factory

    private func makePage(for index: Int) -> ZoomablePageVC? {
        guard let url = APIClient.shared.pageImageURL(comicId: comicId, page: index) else { return nil }
        let cached = imageCache.object(forKey: cacheKey(for: index))
        let upscaled = upscaledCache.object(forKey: upscaledCacheKey(for: index))
        let vc = ZoomablePageVC(imageURL: url, pageIndex: index, cachedImage: upscaled ?? cached)
        vc.onImageLoaded = { [weak self] image in
            guard let self else { return }
            self.imageCache.setObject(image, forKey: self.cacheKey(for: index))
            self.startUpscaleIfNeeded(for: index, image: image)
        }

        // ✅ 如果使用了原图缓存但没有超分缓存，立即开始超分
        if let cachedImage = cached, upscaled == nil {
            startUpscaleIfNeeded(for: index, image: cachedImage)
        }

        return vc
    }

    private func cacheKey(for page: Int) -> NSString {
        "\(comicId)_\(page)" as NSString
    }

    private func upscaledCacheKey(for page: Int) -> NSString {
        "\(comicId)_\(page)_\(upscaleMode.rawValue)" as NSString
    }

    private func upscaleTaskKey(for page: Int, mode: UpscaleMode) -> String {
        "\(page)_\(mode.rawValue)"
    }

    // MARK: - Upscale

    private func startUpscaleIfNeeded(for page: Int, image: UIImage, isPreload: Bool = false) {
        let mode = upscaleMode
        print("🔍 [Upscale] startUpscaleIfNeeded: page \(page), mode \(mode.rawValue), isPreload \(isPreload)")
        guard mode != .off else {
            print("⚠️ [Upscale] 模式为 off，跳过")
            return
        }
        let key = upscaledCacheKey(for: page)
        let taskKey = upscaleTaskKey(for: page, mode: mode)
        if upscaledCache.object(forKey: key) != nil {
            print("⚠️ [Upscale] 已有缓存，跳过: page \(page)")
            return
        }
        // ✅ 检查是否已有任务在运行（使用包含 mode 的 key）
        if let existingTask = upscaleTasks[taskKey], !existingTask.isCancelled {
            print("⚠️ [Upscale] 已有任务运行中，跳过: page \(page)")
            return
        }
        print("✅ [Upscale] 开始超分任务: page \(page)")

        // ✅ 当前页面使用更高优先级，预加载页面使用较低优先级
        let priority: TaskPriority = (page == currentIdx && !isPreload) ? .high : .medium

        upscaleTasks[taskKey] = Task { [weak self] in
            guard let self else {
                print("❌ [ComicReader] self 已释放，跳过: page \(page)")
                return
            }
            print("🔍 [ComicReader] 开始执行超分任务: page \(page)")
            let shouldKeepOriginalSize = self.keepOriginalSize
            let result: UIImage
            do {
                // ✅ 使用 Task.detached 在后台执行，不继承 MainActor
                result = try await Task.detached(priority: priority) {
                    print("🔍 [ComicReader] Task.detached 开始: page \(page)")
                    let r = try ImageUpscaler.shared.upscale(image, mode: mode, keepOriginalSize: shouldKeepOriginalSize)
                    print("🔍 [ComicReader] Task.detached 完成: page \(page)")
                    return r
                }.value
                print("🔍 [ComicReader] 超分结果获取成功: page \(page)")
            } catch is CancellationError {
                // ✅ 任务被取消，静默处理
                print("⚠️ [ComicReader] 任务被取消: page \(page)")
                self.upscaleTasks.removeValue(forKey: taskKey)
                return
            } catch {
                print("❌ [ComicReader] 超分失败: \(error.localizedDescription)")
                self.upscaleTasks.removeValue(forKey: taskKey)
                return
            }
            print("🔍 [ComicReader] 检查任务取消状态: page \(page), isCancelled \(Task.isCancelled)")
            // ✅ 即使任务被取消，也要缓存结果（避免重复计算）
            print("✅ [ComicReader] 超分结果已缓存: page \(page), size \(result.size.width)x\(result.size.height)")
            self.upscaledCache.setObject(result, forKey: key)
            self.upscaleTasks.removeValue(forKey: taskKey)
            // ✅ 如果是当前页面且任务未被取消，立即更新显示
            if !Task.isCancelled && page == self.currentIdx {
                print("✅ [ComicReader] 更新当前页面显示: page \(page)")
                self.updateCurrentPageImage(result)
            } else if Task.isCancelled {
                print("⚠️ [ComicReader] 任务已取消，但结果已缓存: page \(page)")
            } else {
                print("⚠️ [ComicReader] 超分完成但不是当前页面: page \(page), current \(self.currentIdx)")
            }
        }
    }

    private func updateCurrentPageImage(_ image: UIImage) {
        guard let currentVC = viewControllers?.first as? ZoomablePageVC else {
            print("❌ [ComicReader] 无法获取当前 ViewController")
            return
        }
        print("✅ [ComicReader] 更新 VC 图片: \(image.size.width)x\(image.size.height)")
        currentVC.updateImage(image)
    }

    // ✅ 新增：检查并显示当前页面的超分结果
    private func checkAndShowUpscaledImage(for page: Int) {
        let upscaledKey = upscaledCacheKey(for: page)
        if let upscaled = upscaledCache.object(forKey: upscaledKey) {
            print("✅ [ComicReader] 显示超分结果: page \(page), size \(upscaled.size.width)x\(upscaled.size.height)")
            updateCurrentPageImage(upscaled)
        } else {
            print("⚠️ [ComicReader] 无超分缓存: page \(page)")
        }
    }

    // MARK: - Preloading

    /// 预加载：前 2 页，后 4 页（共 7 页）
    func preloadPages(around current: Int) {
        // ✅ 只取消范围外的预加载任务，保留范围内的
        let keepRange = max(0, current - 2)...min(totalPages - 1, current + 4)

        // 先收集要删除的 key，再删除（避免迭代时修改字典）
        let preloadKeysToRemove = preloadTasks.keys.filter { !keepRange.contains($0) }
        for page in preloadKeysToRemove {
            preloadTasks[page]?.cancel()
            preloadTasks.removeValue(forKey: page)
        }

        // ✅ 清理不在当前范围内的超分任务（key 现在是 "page_mode" 格式）
        let upscaleKeysToRemove = upscaleTasks.keys.filter { taskKey in
            let parts = taskKey.split(separator: "_")
            if let pageStr = parts.first, let page = Int(pageStr) {
                return !keepRange.contains(page)
            }
            return false
        }
        if !upscaleKeysToRemove.isEmpty {
            print("⚠️ [Preload] 取消超分任务: \(upscaleKeysToRemove), 保留范围: \(keepRange)")
        }
        for taskKey in upscaleKeysToRemove {
            upscaleTasks[taskKey]?.cancel()
            upscaleTasks.removeValue(forKey: taskKey)
        }

        let mode = upscaleMode
        let range = keepRange
        for page in range {
            guard page != current else { continue }
            let key = cacheKey(for: page)
            let upscaledKey = upscaledCacheKey(for: page)

            // ✅ 如果预加载任务已存在，跳过
            if preloadTasks[page] != nil { continue }

            // 检查原图是否已缓存
            if let cachedImage = imageCache.object(forKey: key) {
                // 原图已缓存，检查是否需要超分（使用包含 mode 的 key 检查）
                let taskKey = upscaleTaskKey(for: page, mode: mode)
                if mode != .off && upscaledCache.object(forKey: upscaledKey) == nil && upscaleTasks[taskKey] == nil {
                    startUpscaleIfNeeded(for: page, image: cachedImage, isPreload: true)
                }
                continue
            }

            guard let url = APIClient.shared.pageImageURL(comicId: comicId, page: page) else { continue }

            preloadTasks[page] = Task { [weak self] in
                guard let self else { return }
                let request = APIClient.shared.authenticatedRequest(url: url)
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, let image = UIImage(data: data) else { return }
                    // ✅ 回到 MainActor 更新缓存和启动超分
                    await MainActor.run { () -> Void in
                        self.imageCache.setObject(image, forKey: key)
                        // 预加载完成后，通过统一方法进行超分
                        if mode != .off {
                            self.startUpscaleIfNeeded(for: page, image: image, isPreload: true)
                        }
                        self.preloadTasks.removeValue(forKey: page)
                    }
                } catch {
                    // 预加载失败静默忽略，回到 MainActor 清理
                    await MainActor.run { () -> Void in
                        self.preloadTasks.removeValue(forKey: page)
                    }
                }
            }
        }
    }
}

// MARK: - 可缩放单页 VC

class ZoomablePageVC: UIViewController, UIScrollViewDelegate {
    let imageURL: URL
    let pageIndex: Int
    private let cachedImage: UIImage?
    var onImageLoaded: ((UIImage) -> Void)?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    init(imageURL: URL, pageIndex: Int, cachedImage: UIImage? = nil) {
        self.imageURL = imageURL
        self.pageIndex = pageIndex
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

        let request = APIClient.shared.authenticatedRequest(url: imageURL)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
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
        print("✅ [ZoomablePageVC] updateImage: \(image.size.width)x\(image.size.height)")
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
