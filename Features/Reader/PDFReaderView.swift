import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let comicId: String
    var initialPage: Int = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLoading = false
    @State private var loadError = false
    @State private var reloadID = UUID()
    @State private var currentPage = 0
    @State private var totalPages = 0
    @State private var activityTracker: ReadingActivityTracker?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PDFKitView(
                url: api.pdfURL(comicId: comicId),
                initialPage: initialPage,
                reloadID: reloadID,
                isActive: scenePhase != .background,
                isLoading: $isLoading,
                loadError: $loadError,
                onDocumentLoaded: { pages in
                    totalPages = pages
                    startOrUpdateActivity(page: min(max(initialPage, 0), max(pages - 1, 0)), totalPages: pages)
                },
                onPageChanged: { page in
                    currentPage = page
                    startOrUpdateActivity(page: page, totalPages: totalPages)
                }
            )
            .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            }

            if loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                    Text("PDF 加载失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("重试") {
                        loadError = false
                        reloadID = UUID() // 强制重建 PDFKitView
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .readerStatusBarHidden(true)
        .onDisappear {
            Task { await finishActivity() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                activityTracker?.setActive(true)
            } else if newPhase == .background || newPhase == .inactive {
                activityTracker?.setActive(false)
                Task { await flushActivity() }
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                    .padding(8)
            }
        }
    }

    private func startOrUpdateActivity(page: Int, totalPages: Int) {
        guard totalPages > 0 else { return }
        if activityTracker?.comicId != comicId {
            activityTracker = ReadingActivityTracker(comicId: comicId)
            activityTracker?.start(page: page, totalPages: totalPages)
        } else {
            activityTracker?.updatePage(page: page, totalPages: totalPages)
        }
    }

    private func flushActivity() async {
        startOrUpdateActivity(page: currentPage, totalPages: totalPages)
        do {
            try await activityTracker?.flush(finalize: false)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
    }

    private func finishActivity() async {
        startOrUpdateActivity(page: currentPage, totalPages: totalPages)
        do {
            try await activityTracker?.flush(finalize: true)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
        activityTracker = nil
    }
}

// MARK: - PDFKit 桥接

struct PDFKitView: UIViewRepresentable {
    let url: URL?
    let initialPage: Int
    let reloadID: UUID
    let isActive: Bool
    @Binding var isLoading: Bool
    @Binding var loadError: Bool
    let onDocumentLoaded: (Int) -> Void
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDocumentLoaded: onDocumentLoaded,
            onPageChanged: onPageChanged,
            onLoadFailed: { loadError = true }
        )
    }

    @MainActor
    class Coordinator {
        private struct ReadingPosition {
            let pageIndex: Int
            let zoomRatio: CGFloat
            let point: CGPoint?
        }

        var dataTask: Task<Void, Never>?
        var currentLoadID: UUID?
        var lastReloadID: UUID?
        var lastURL: URL?
        var observer: NSObjectProtocol?
        private var memoryWarningObserver: NSObjectProtocol?
        private var restoreTask: Task<Void, Never>?
        private var localFileURL: URL?
        private var readingPosition: ReadingPosition?
        private var isActive = true
        private var hasNotifiedDocumentLoaded = false
        var onDocumentLoaded: (Int) -> Void
        var onPageChanged: (Int) -> Void
        var onLoadFailed: () -> Void

        init(
            onDocumentLoaded: @escaping (Int) -> Void,
            onPageChanged: @escaping (Int) -> Void,
            onLoadFailed: @escaping () -> Void
        ) {
            self.onDocumentLoaded = onDocumentLoaded
            self.onPageChanged = onPageChanged
            self.onLoadFailed = onLoadFailed
        }

        deinit {
            dataTask?.cancel()
            restoreTask?.cancel()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
            }
            if let localFileURL {
                try? FileManager.default.removeItem(at: localFileURL)
            }
        }

        func cancelLoading() {
            dataTask?.cancel()
            dataTask = nil
            restoreTask?.cancel()
            restoreTask = nil
            currentLoadID = nil
            lastReloadID = nil
            lastURL = nil
        }

        func setActive(_ active: Bool, in pdfView: PDFView) {
            guard isActive != active else { return }
            isActive = active
            if active {
                scheduleRestore(in: pdfView)
            } else {
                suspendDocument(in: pdfView)
            }
        }

        func installDocumentFile(_ fileURL: URL, initialPage: Int, in pdfView: PDFView) -> Bool {
            resetDocument(in: pdfView)
            localFileURL = fileURL
            readingPosition = ReadingPosition(pageIndex: initialPage, zoomRatio: 1, point: nil)
            return !isActive || openLocalDocument(in: pdfView)
        }

        func resetDocument(in pdfView: PDFView) {
            restoreTask?.cancel()
            restoreTask = nil
            pdfView.document = nil
            if let localFileURL {
                try? FileManager.default.removeItem(at: localFileURL)
            }
            localFileURL = nil
            readingPosition = nil
            hasNotifiedDocumentLoaded = false
        }

        private func suspendDocument(in pdfView: PDFView) {
            restoreTask?.cancel()
            restoreTask = nil
            if let document = pdfView.document, let page = pdfView.currentPage {
                let fitScale = pdfView.scaleFactorForSizeToFit
                readingPosition = ReadingPosition(
                    pageIndex: document.index(for: page),
                    zoomRatio: fitScale > 0 ? pdfView.scaleFactor / fitScale : 1,
                    point: pdfView.currentDestination?.point
                )
            }
            autoreleasepool {
                pdfView.document = nil
            }
        }

        private func scheduleRestore(in pdfView: PDFView) {
            guard isActive, localFileURL != nil, pdfView.document == nil,
                  restoreTask == nil else { return }
            restoreTask = Task { @MainActor [weak self, weak pdfView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let pdfView, self.isActive else { return }
                self.restoreTask = nil
                if !self.openLocalDocument(in: pdfView) {
                    self.onLoadFailed()
                }
            }
        }

        private func openLocalDocument(in pdfView: PDFView) -> Bool {
            guard let localFileURL,
                  let document = PDFDocument(url: localFileURL),
                  document.pageCount > 0 else { return false }
            let position = readingPosition
            let index = min(max(position?.pageIndex ?? 0, 0), document.pageCount - 1)
            pdfView.autoScales = true
            pdfView.document = document
            if let page = document.page(at: index) {
                pdfView.go(to: page)
                pdfView.layoutIfNeeded()
                if let position, abs(position.zoomRatio - 1) > 0.01 {
                    let scale = pdfView.scaleFactorForSizeToFit * position.zoomRatio
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
                    if let point = position.point {
                        pdfView.go(to: PDFDestination(page: page, at: point))
                    }
                }
            }
            if !hasNotifiedDocumentLoaded {
                hasNotifiedDocumentLoaded = true
                onDocumentLoaded(document.pageCount)
            }
            onPageChanged(index)
            return true
        }

        func observeMemoryWarnings(in pdfView: PDFView) {
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                Task { @MainActor [weak self, weak pdfView] in
                    guard let self, let pdfView, pdfView.document != nil else { return }
                    self.suspendDocument(in: pdfView)
                    self.scheduleRestore(in: pdfView)
                }
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
                self.memoryWarningObserver = nil
            }
        }

        func observePageChanges(in pdfView: PDFView) {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                Task { @MainActor [weak self, weak pdfView] in
                    guard let self,
                          let pdfView,
                          let document = pdfView.document,
                          let page = pdfView.currentPage else { return }
                    self.onPageChanged(document.index(for: page))
                }
            }
        }
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .black
        pdfView.usePageViewController(true, withViewOptions: nil)
        context.coordinator.observePageChanges(in: pdfView)
        context.coordinator.observeMemoryWarnings(in: pdfView)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.onDocumentLoaded = onDocumentLoaded
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onLoadFailed = { loadError = true }
        // 只在 reloadID 或 url 变化时重新加载
        let coordinator = context.coordinator
        coordinator.setActive(isActive, in: uiView)
        guard coordinator.lastReloadID != reloadID || coordinator.lastURL != url else {
            return
        }
        coordinator.lastReloadID = reloadID
        coordinator.lastURL = url
        coordinator.dataTask?.cancel()
        coordinator.resetDocument(in: uiView)

        guard let url else {
            coordinator.currentLoadID = nil
            DispatchQueue.main.async {
                isLoading = false
                loadError = true
            }
            return
        }

        DispatchQueue.main.async {
            isLoading = true
            loadError = false
        }

        let loadID = UUID()
        coordinator.currentLoadID = loadID
        let task = Task { @MainActor [weak uiView, weak coordinator] in
            do {
                let temporaryURL = try await APIClient.shared.authenticatedDownload(
                    from: url,
                    timeout: 60
                )
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard !Task.isCancelled, let coordinator, let uiView,
                      coordinator.currentLoadID == loadID else { return }
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NowenReaderLite-PDF-\(UUID().uuidString).pdf")
                try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
                let loaded = coordinator.installDocumentFile(fileURL, initialPage: initialPage, in: uiView)
                coordinator.dataTask = nil
                coordinator.currentLoadID = nil
                isLoading = false
                if !loaded {
                    coordinator.resetDocument(in: uiView)
                    loadError = true
                }
            } catch {
                guard !Task.isCancelled, let coordinator,
                      coordinator.currentLoadID == loadID else { return }
                coordinator.dataTask = nil
                coordinator.currentLoadID = nil
                isLoading = false
                loadError = true
            }
        }
        coordinator.dataTask = task
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.cancelLoading()
        coordinator.stopObserving()
        coordinator.resetDocument(in: uiView)
    }
}
