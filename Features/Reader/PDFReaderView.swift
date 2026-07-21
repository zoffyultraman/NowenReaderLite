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
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
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
    @Binding var isLoading: Bool
    @Binding var loadError: Bool
    let onDocumentLoaded: (Int) -> Void
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDocumentLoaded: onDocumentLoaded,
            onPageChanged: onPageChanged
        )
    }

    class Coordinator {
        var dataTask: URLSessionDataTask?
        var lastReloadID: UUID?
        var lastURL: URL?
        var observer: NSObjectProtocol?
        var onDocumentLoaded: (Int) -> Void
        var onPageChanged: (Int) -> Void

        init(
            onDocumentLoaded: @escaping (Int) -> Void,
            onPageChanged: @escaping (Int) -> Void
        ) {
            self.onDocumentLoaded = onDocumentLoaded
            self.onPageChanged = onPageChanged
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
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
                guard let self,
                      let pdfView,
                      let document = pdfView.document,
                      let page = pdfView.currentPage else { return }
                self.onPageChanged(document.index(for: page))
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
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.onDocumentLoaded = onDocumentLoaded
        context.coordinator.onPageChanged = onPageChanged
        // 只在 reloadID 或 url 变化时重新加载
        let coordinator = context.coordinator
        guard coordinator.lastReloadID != reloadID || coordinator.lastURL != url else {
            return
        }
        coordinator.lastReloadID = reloadID
        coordinator.lastURL = url
        coordinator.dataTask?.cancel()

        guard let url else {
            DispatchQueue.main.async { loadError = true }
            return
        }

        DispatchQueue.main.async {
            isLoading = true
            loadError = false
        }

        let request = APIClient.shared.authenticatedRequest(url: url, timeout: 60)
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                if let data, let doc = PDFDocument(data: data) {
                    uiView.document = doc
                    let pageCount = doc.pageCount
                    let targetIndex = min(max(initialPage, 0), max(pageCount - 1, 0))
                    if let targetPage = doc.page(at: targetIndex) {
                        uiView.go(to: targetPage)
                    }
                    onDocumentLoaded(pageCount)
                    if let page = uiView.currentPage {
                        onPageChanged(doc.index(for: page))
                    }
                } else {
                    loadError = true
                }
            }
        }
        coordinator.dataTask = task
        task.resume()
    }
}
