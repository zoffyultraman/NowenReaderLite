import SwiftUI
import SwiftData

struct ComicDetailPreview: Hashable {
    let id: String
    let title: String
    var author: String? = nil
    var publisher: String? = nil
    var year: Int? = nil
    var language: String? = nil
    var pageCount: Int = 0
    var isNovel: Bool = false
    var fileSize: Int64? = nil
    var rating: Double? = nil
    var formatBadge: String = ""
}

extension ComicDetailPreview {
    init(comic: GroupComicItem) {
        self.init(
            id: comic.id, title: comic.title, pageCount: comic.pageCount,
            isNovel: comic.isNovel, fileSize: comic.fileSize,
            formatBadge: comic.formatBadge
        )
    }

    init(comic: Comic) {
        self.init(
            id: comic.id, title: comic.title, author: comic.author,
            publisher: comic.publisher, year: comic.year, language: comic.language,
            pageCount: comic.pageCount, isNovel: comic.isNovel,
            fileSize: comic.fileSize, rating: comic.rating,
            formatBadge: comic.formatBadge
        )
    }
}

struct ComicDetailRoute: Hashable {
    let preview: ComicDetailPreview

    init(comic: Comic) {
        preview = ComicDetailPreview(comic: comic)
    }
}

extension View {
    func comicDetailNavigation() -> some View {
        navigationDestination(for: ComicDetailRoute.self) { route in
            if let seriesId = Comic.seriesId(from: route.preview.id) {
                SeriesDetailView(seriesId: seriesId)
                    .bookCoverDestination(id: "comic-\(route.preview.id)")
            } else {
                ComicDetailView(comicId: route.preview.id, initialPreview: route.preview)
                    .bookCoverDestination(id: "comic-\(route.preview.id)")
            }
        }
    }
}

struct ComicDetailView: View {
    let comicId: String
    var groupContext: ReadingGroupContext? = nil
    var initialPreview: ComicDetailPreview? = nil
    @State private var viewModel = DetailViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api
    @State private var showDeleteSheet = false
    @State private var shouldDismissAfterDelete = false

    private var canDeleteCurrentComic: Bool {
        viewModel.comic?.canManage == true && !api.isOfflineMode && api.isLoggedIn
    }

    private var canExportCurrentComic: Bool {
        viewModel.comic?.canDownloadOriginalFile == true && !api.isOfflineMode
    }

    private var currentPhysicalPath: String? {
        guard let loc = viewModel.comic?.fileLocation else { return nil }
        let abs = loc.absolutePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !abs.isEmpty { return abs }
        let dir = loc.realDirPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return dir.isEmpty ? nil : dir
    }

    private var hasToolbarMenuActions: Bool {
        canExportCurrentComic || currentPhysicalPath != nil || canDeleteCurrentComic
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let preview = viewModel.comic.map(ComicDetailPreview.init(comic:)) ?? initialPreview {
                    ComicDetailHeader(preview: preview)
                }

                if let comic = viewModel.comic {
                    ComicDetailContent(
                        comic: comic,
                        groupContext: groupContext,
                        viewModel: viewModel,
                        onSelectTag: { tagName in
                            api.activateTagFilter(tagName)
                        }
                    )
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("详情加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") {
                            Task { await viewModel.load(id: comicId) }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if hasToolbarMenuActions {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.exportingEditionComicId != nil {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Menu {
                        if canExportCurrentComic, let comic = viewModel.comic {
                            Button {
                                Task {
                                    await viewModel.exportOriginalFile(
                                        comicId: comic.id,
                                        downloadPath: nil,
                                        preferredFilename: comic.fileLocation?.filename ?? comic.filename
                                    )
                                }
                            } label: {
                                Label("导出原文件", systemImage: "square.and.arrow.up")
                            }
                            .disabled(viewModel.exportingEditionComicId != nil)
                        }

                        if let physicalPath = currentPhysicalPath {
                            Button {
                                UIPasteboard.general.string = physicalPath
                            } label: {
                                Label("复制物理路径", systemImage: "doc.on.doc")
                            }
                        }

                        if canDeleteCurrentComic {
                            if canExportCurrentComic || currentPhysicalPath != nil {
                                Divider()
                            }
                            Button(role: .destructive) {
                                showDeleteSheet = true
                            } label: {
                                Label("删除作品", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .alert("操作未完成", isPresented: $viewModel.isActionErrorPresented) {
            Button("重试") {
                Task { await viewModel.retryFailedAction() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(viewModel.actionErrorMessage ?? "请稍后重试。")
        }
        .sheet(item: $viewModel.exportedFileItem) { item in
            OriginalFileShareSheet(fileURL: item.url)
        }
        .sheet(isPresented: $showDeleteSheet, onDismiss: {
            if shouldDismissAfterDelete {
                dismiss()
            }
        }) {
            if let comic = viewModel.comic {
                let editionsCount = comic.resolvedEditions.count
                DeleteContentConfirmSheet(
                    title: "删除作品",
                    description: editionsCount > 1
                        ? "《\(comic.title)》包含 \(editionsCount) 个格式版本，请选择移除方式。"
                        : "即将删除《\(comic.title)》，请选择移除方式。",
                    showEditionOption: editionsCount > 1,
                    editionCount: editionsCount,
                    onConfirm: { deleteFiles, deleteEditions in
                        let outcome = try await viewModel.deleteCurrentComic(
                            deleteFiles: deleteFiles,
                            deleteEditions: deleteEditions
                        )
                        if outcome == .shouldDismiss {
                            shouldDismissAfterDelete = true
                        }
                    }
                )
            }
        }
        .onChange(of: api.tagFilterNavigationRevision) { _, _ in
            dismiss()
        }
        .task(id: comicId) {
            viewModel.setModelContext(modelContext)
            DownloadManager.shared.setModelContext(modelContext)
            let targetId = viewModel.currentComicId.flatMap { $0.isEmpty ? nil : $0 } ?? comicId
            await viewModel.load(id: targetId)
        }
    }
}

private struct ComicDetailHeader: View {
    let preview: ComicDetailPreview

    var body: some View {
        ComicCoverInfoSection(
            comicId: preview.id, title: preview.title, author: preview.author,
            publisher: preview.publisher, year: preview.year, language: preview.language,
            pageCount: preview.pageCount, isNovel: preview.isNovel,
            fileSize: preview.fileSize, rating: preview.rating,
            formatBadge: preview.formatBadge
        )
    }
}

// MARK: - 漫画详情内容

struct ComicDetailContent: View {
    let comic: Comic
    let groupContext: ReadingGroupContext?
    let viewModel: DetailViewModel
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ComicActionButtonsSection(
                comic: comic,
                groupContext: groupContext,
                viewModel: viewModel
            )

            ComicEditionsSection(
                activeComicId: comic.id,
                editions: comic.resolvedEditions,
                isSwitchingEdition: viewModel.isSwitchingEdition,
                onSelectEdition: { targetId in
                    Task { await viewModel.switchEdition(to: targetId) }
                }
            )

            ComicProgressSection(
                progress: comic.progress,
                lastReadPage: comic.lastReadPage,
                pageCount: comic.pageCount,
                isNovel: comic.isNovel
            )

            ReadingStatusSection(
                currentStatus: comic.readingStatus,
                isUpdating: viewModel.isUpdatingReadingStatus,
                onSelect: { status in
                    Task { await viewModel.updateReadingStatus(status) }
                }
            )
            .disabled(viewModel.isPerformingAction)

            ComicTagsSection(tags: comic.tags, onSelectTag: onSelectTag)

            ComicDescriptionSection(description: comic.description)

            ComicFileLocationSection(
                comicId: comic.id,
                filename: comic.filename,
                relativePath: comic.relativePath,
                fileLocation: comic.fileLocation,
                isImageFolder: comic.isImageFolder
            )

            Spacer(minLength: 40)
        }
    }
}

// MARK: - 错误状态
// 轻量视图：retry 闭包每次 body 求值时重建，但视图简单，不会引起可见问题

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: retry) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 100)
    }
}

// MARK: - 简易流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = max(totalHeight, y + rowHeight)
        }

        return (positions, sizes, CGSize(width: maxWidth, height: totalHeight))
    }
}

// MARK: - 封面 + 信息段落

struct ComicCoverInfoSection: View {
    let comicId: String
    let title: String
    let author: String?
    let publisher: String?
    let year: Int?
    let language: String?
    let pageCount: Int
    let isNovel: Bool
    let fileSize: Int64?
    let rating: Double?
    var formatBadge: String = ""
    @Environment(APIClient.self) private var api

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AuthenticatedImage(serverURL: api.serverURL, comicId: comicId, thumbnail: true)
                .frame(width: 130, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .bookCoverSource(id: "reader-\(comicId)")

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if !formatBadge.isEmpty {
                    Text(formatBadge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let author, !author.isEmpty {
                    Label(author, systemImage: "person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let publisher, !publisher.isEmpty {
                    Label(publisher, systemImage: "building.2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let year {
                    Label(year.formatted(.number.grouping(.never)), systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let language, !language.isEmpty {
                    Label(language, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if pageCount > 0 {
                    Label("\(pageCount) \(isNovel ? "章" : "页")", systemImage: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let size = fileSize, size > 0 {
                    Label(formatFileSize(size), systemImage: "internaldrive")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let rating, rating > 0 {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= Int(rating) ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

// MARK: - 操作按钮段落

struct ComicActionButtonsSection: View {
    let comic: Comic
    let groupContext: ReadingGroupContext?
    let viewModel: DetailViewModel

    var body: some View {
        HStack(spacing: 12) {
            // 收藏按钮
            Button {
                Task { await viewModel.toggleFavorite() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isUpdatingFavorite {
                        ProgressView().controlSize(.small)
                        Text("处理中")
                    } else {
                        Label(
                            comic.isFavorite ? "已收藏" : "收藏",
                            systemImage: comic.isFavorite ? "heart.fill" : "heart"
                        )
                    }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(comic.isFavorite ? Color.red.opacity(0.1) : Color(uiColor: .systemGray6))
                .foregroundStyle(comic.isFavorite ? .red : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(viewModel.isPerformingAction)
            .sensoryFeedback(.success, trigger: comic.isFavorite)

            // 下载按钮
            DownloadButton(comic: comic)

            // 阅读按钮
            NavigationLink {
                comic.readerView(groupContext: groupContext)
                    .bookCoverDestination(id: "reader-\(comic.id)")
            } label: {
                Label(
                    comic.lastReadPage > 0 ? "继续阅读" : "开始阅读",
                    systemImage: "book.fill"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - 下载按钮

struct DownloadButton: View {
    let comic: Comic
    private let downloadManager = DownloadManager.shared

    var body: some View {
        let task = downloadManager.task(for: comic.id)
        let hasActiveTask = task != nil
        let isDownloaded = task?.state == .completed || (!hasActiveTask && downloadManager.isDownloaded(comicId: comic.id))
        let isDownloading = task?.state == .downloading || task?.state == .waiting
        let isPaused = task?.state == .paused

        if isDownloaded {
            Button {} label: {
                Label("已缓存", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if isDownloading || isPaused {
            HStack(spacing: 8) {
                Button {
                    if isDownloading {
                        downloadManager.pause(comicId: comic.id)
                    } else {
                        downloadManager.resume(comicId: comic.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(Int((task?.progress ?? 0) * 100))%")
                                .font(.subheadline.weight(.medium))
                        } else {
                            Label("继续", systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                Button {
                    downloadManager.cancel(comicId: comic.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        } else if task?.state == .failed {
            HStack(spacing: 8) {
                Button {
                    downloadManager.download(
                        comicId: comic.id,
                        title: comic.title,
                        pageCount: comic.pageCount,
                        fileSize: comic.fileSize,
                        isNovel: comic.isNovel
                    )
                } label: {
                    HStack(spacing: 6) {
                        Label("重新缓存", systemImage: "arrow.clockwise.circle.fill")
                            .font(.subheadline.weight(.medium))
                        if let t = task {
                            Text("\(t.completedPages)/\(t.totalPages)")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                Button {
                    downloadManager.cancel(comicId: comic.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.gray.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        } else if downloadManager.storageLimitBytes > 0 && !downloadManager.isStorageUsageLoaded {
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在计算空间")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemGray6))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if downloadManager.wouldExceedLimit(
            comicId: comic.id,
            pageCount: comic.pageCount,
            fileSize: comic.fileSize
        ) {
            Button {} label: {
                Label("空间不足", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else {
            Button {
                downloadManager.download(
                    comicId: comic.id,
                    title: comic.title,
                    pageCount: comic.pageCount,
                    fileSize: comic.fileSize,
                    isNovel: comic.isNovel
                )
            } label: {
                Label("离线缓存", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - 多格式版本切换与文件位置区块

struct ExportedOriginalFileItem: Identifiable, Equatable {
    let id: String
    let url: URL

    init(id: String = UUID().uuidString, url: URL) {
        self.id = id
        self.url = url
    }
}

struct OriginalFileShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController,
           let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let rootView = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController?.view {
            popover.sourceView = rootView
            popover.sourceRect = CGRect(
                x: rootView.bounds.midX,
                y: rootView.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ComicEditionsSection: View {
    let activeComicId: String
    let editions: [ComicEditionInfo]
    let isSwitchingEdition: Bool
    let onSelectEdition: (String) -> Void

    var body: some View {
        if editions.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("格式版本")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if isSwitchingEdition {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(editions) { edition in
                            let isActive = edition.comicId == activeComicId
                                || (edition.isCurrent && activeComicId.isEmpty)
                            ComicEditionChipView(
                                edition: edition,
                                isActive: isActive,
                                isDisabled: isSwitchingEdition || isActive,
                                onSelect: { onSelectEdition(edition.comicId) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct ComicEditionChipView: View {
    let edition: ComicEditionInfo
    let isActive: Bool
    let isDisabled: Bool
    let onSelect: () -> Void

    private var secondaryInfo: String {
        var parts: [String] = []
        if edition.fileSize > 0 {
            parts.append(formatFileSize(edition.fileSize))
        }
        if edition.progress > 0 {
            parts.append("\(edition.progress)%")
        } else if edition.isPreferred && !isActive {
            parts.append("推荐")
        }
        return parts.joined(separator: " / ")
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(edition.displayChipLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if !secondaryInfo.isEmpty {
                    Text(secondaryInfo)
                        .font(.caption2.monospacedDigit())
                        .opacity(isActive ? 0.88 : 0.72)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isActive ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isActive ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                in: Capsule()
            )
            .overlay {
                if !isActive {
                    Capsule()
                        .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct ComicFileLocationSection: View {
    let comicId: String
    let filename: String?
    let relativePath: String?
    let fileLocation: ComicFileLocation?
    let isImageFolder: Bool
    @State private var copiedPath = false

    private var hasLocationContent: Bool {
        if fileLocation != nil { return true }
        let rel = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !rel.isEmpty || !name.isEmpty
    }

    private var physicalPathToCopy: String? {
        let abs = fileLocation?.absolutePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !abs.isEmpty { return abs }
        let dir = fileLocation?.realDirPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return dir.isEmpty ? nil : dir
    }

    private var relativeSummary: String {
        if let fileLocation {
            return fileLocation.displayRelativeSummary
        }
        if let relativePath, !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return relativePath
        }
        return filename ?? comicId
    }

    private var displayFilename: String {
        let locName = fileLocation?.filename.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !locName.isEmpty { return locName }
        return filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        if hasLocationContent {
            VStack(alignment: .leading, spacing: 6) {
                Label("文件信息", systemImage: "doc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(relativeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if !displayFilename.isEmpty {
                        Text(isImageFolder ? "目录文件：\(displayFilename)" : displayFilename)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if fileLocation?.existsOnDisk == false {
                        Label("磁盘原文件当前不可见，可能已被移动或下线", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }

                    if let physicalPath = physicalPathToCopy {
                        HStack(spacing: 8) {
                            Text(physicalPath)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                UIPasteboard.general.string = physicalPath
                                copiedPath = true
                            } label: {
                                Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(copiedPath ? "已复制路径" : "复制物理路径")
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 进度段落

struct ComicProgressSection: View {
    let progress: Int
    let lastReadPage: Int
    let pageCount: Int
    let isNovel: Bool

    var body: some View {
        if progress > 0, pageCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("阅读进度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(lastReadPage + 1)/\(pageCount)\(isNovel ? "章" : "页")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(progress) / 100)
                        Text("\(progress)%")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                            .frame(width: geo.size.width, height: 14)
                    }
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 阅读状态

struct ReadingStatusSection: View {
    let currentStatus: String?
    var isUpdating = false
    let onSelect: (String?) -> Void

    private static let statuses: [(key: String, icon: String)] = [
        ("want", "bookmark"),
        ("reading", "book.fill"),
        ("finished", "checkmark.circle.fill"),
        ("shelved", "archivebox"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("阅读状态")
                if isUpdating {
                    ProgressView().controlSize(.mini)
                    Text("更新中…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.statuses, id: \.key) { status in
                        let isSelected = currentStatus == status.key
                        Button {
                            onSelect(isSelected ? nil : status.key)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: status.icon)
                                    .font(.system(size: 11))
                                Text(ReadingStatus.label(for: status.key))
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(isSelected ? Color.accentColor : Color(uiColor: .systemGray6))
                            .clipShape(Capsule())
                            .overlay {
                                Capsule().stroke(isSelected ? Color.clear : Color(uiColor: .systemGray4), lineWidth: 0.5)
                            }
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - 标签段落

struct ComicTagsSection: View {
    let tags: [TagItem]?
    var onSelectTag: ((String) -> Void)? = nil

    var body: some View {
        if let tags, !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.name) { tag in
                        if let onSelectTag {
                            Button {
                                onSelectTag(tag.name)
                            } label: {
                                Text(tag.name)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("点击跳转到书架按此标签筛选")
                        } else {
                            Text(tag.name)
                                .font(.caption2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 管理员内容删除确认弹窗（Phase 4）

struct DeleteContentConfirmSheet: View {
    let title: String
    let description: String
    var showEditionOption: Bool = false
    var editionCount: Int = 0
    var initialDeleteEditions: Bool = true
    let onConfirm: (_ deleteFiles: Bool, _ deleteEditions: Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deleteFiles = false
    @State private var deleteEditions = true
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $deleteFiles) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("同时删除磁盘源文件")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(deleteFiles ? .red : .primary)
                            Text(
                                deleteFiles
                                    ? "将从磁盘永久删除源文件并清理空子目录（不可恢复）"
                                    : "仅从书库移除并忽略自动扫描，保留磁盘文件"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.red)

                    if showEditionOption {
                        Toggle(isOn: $deleteEditions) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("同时删除关联格式版本")
                                    .font(.subheadline.weight(.medium))
                                Text(
                                    editionCount > 1
                                        ? "一并移除全部 \(editionCount) 个格式版本"
                                        : "一并移除同一作品的其他格式"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("删除选项")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        submitDelete()
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在删除...")
                            } else {
                                Text(deleteFiles ? "删除源文件" : "确认移除")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .onAppear {
                deleteEditions = initialDeleteEditions
            }
        }
    }

    private func submitDelete() {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            defer { isDeleting = false }
            do {
                try await onConfirm(deleteFiles, deleteEditions)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
func cleanLocalContentCaches(comicIds: [String], modelContext: ModelContext?) {
    let uniqueIds = Array(Set(comicIds.filter { !$0.isEmpty }))
    guard !uniqueIds.isEmpty else { return }

    DownloadManager.shared.deleteDownloads(comicIds: uniqueIds)
    for id in uniqueIds {
        ReadingRecordManager.shared.remove(comicId: id)
    }
    if let context = modelContext {
        let targetSet = Set(uniqueIds)
        let cached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "删除内容前查询本地缓存")
        var removed = false
        for item in cached where targetSet.contains(item.id) {
            context.delete(item)
            removed = true
        }
        if removed {
            context.saveOrLog()
        }
    }
    APIClient.shared.contentMutationRevision += 1
}

// MARK: - 简介段落

struct ComicDescriptionSection: View {
    let description: String?
    @State private var isExpanded = false

    private var text: String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canExpand: Bool {
        guard let text else { return false }
        return text.count > 100 || text.filter(\.isNewline).count >= 3
    }

    var body: some View {
        if let text {
            VStack(alignment: .leading, spacing: 8) {
                Label("作品简介", systemImage: "text.alignleft")
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .lineLimit(isExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)

                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isExpanded ? "收起" : "展开",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class DetailViewModel {
    var comic: Comic?
    var currentComicId: String?
    var isLoading = false
    var isSwitchingEdition = false
    var exportingEditionComicId: String?
    var exportedFileItem: ExportedOriginalFileItem?
    var errorMessage: String?
    var isUpdatingFavorite = false
    var isUpdatingReadingStatus = false
    var isActionErrorPresented = false
    var actionErrorMessage: String?

    var isPerformingAction: Bool { isUpdatingFavorite || isUpdatingReadingStatus }

    private enum FailedAction {
        case favorite
        case readingStatus(String?)
        case switchEdition(String)
        case exportOriginalFile(comicId: String, downloadPath: String?, preferredFilename: String?)
    }
    private var failedAction: FailedAction?

    private let api = APIClient.shared
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(id: String) async {
        guard !isLoading else { return }
        currentComicId = id
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await api.fetchComic(id: id)
            currentComicId = loaded.id
            comic = loaded
        } catch {
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            // 离线 fallback：从本地已下载数据构造 Comic
            if let meta = OfflineFileManager.shared.loadMeta(comicId: id) {
                let cached = cachedComic(id: id)
                let isNovel = cached?.type == "novel"
                    || downloadedRecord(id: id)?.isNovel == true
                    || meta.isNovel == true
                comic = Comic(
                    id: meta.comicId,
                    title: cached?.title ?? meta.title,
                    author: cached?.author,
                    publisher: nil,
                    description: nil,
                    genre: nil,
                    language: nil,
                    year: nil,
                    pageCount: meta.pageCount,
                    fileSize: meta.fileSize,
                    lastReadPage: cached?.lastReadPage ?? 0,
                    totalReadTime: nil,
                    readingStatus: cached?.readingStatus,
                    lastReadAt: cached?.lastReadAt?.iso8601String,
                    metadataSource: nil,
                    coverUrl: cached?.coverUrl,
                    coverAspectRatio: nil,
                    rating: cached?.rating,
                    isFavorite: cached?.isFavorite ?? false,
                    type: isNovel ? "novel" : "comic",
                    filename: nil,
                    titleSortKey: nil,
                    sortOrder: nil,
                    tags: nil,
                    categories: nil
                )
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func switchEdition(to targetComicId: String) async {
        guard targetComicId != (comic?.id ?? currentComicId), !isSwitchingEdition else { return }
        isSwitchingEdition = true
        defer { isSwitchingEdition = false }
        do {
            let loaded = try await api.fetchComic(id: targetComicId)
            currentComicId = loaded.id
            comic = loaded
            failedAction = nil
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.error("切换格式版本失败: \(error)")
            failedAction = .switchEdition(targetComicId)
            actionErrorMessage = "切换格式版本失败：\(error.localizedDescription)"
            isActionErrorPresented = true
        }
    }

    func exportOriginalFile(
        comicId: String,
        downloadPath: String? = nil,
        preferredFilename: String? = nil
    ) async {
        guard exportingEditionComicId == nil else { return }
        exportingEditionComicId = comicId
        defer { exportingEditionComicId = nil }
        do {
            let fileURL = try await api.downloadOriginalComicFile(
                comicId: comicId,
                downloadPath: downloadPath,
                preferredFilename: preferredFilename
            )
            exportedFileItem = ExportedOriginalFileItem(url: fileURL)
            failedAction = nil
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.error("下载原文件失败: \(error)")
            failedAction = .exportOriginalFile(
                comicId: comicId,
                downloadPath: downloadPath,
                preferredFilename: preferredFilename
            )
            actionErrorMessage = "下载原文件失败：\(error.localizedDescription)"
            isActionErrorPresented = true
        }
    }

    enum DeleteComicOutcome {
        case shouldDismiss
        case switchedToRemainingEdition
    }

    func deleteCurrentComic(deleteFiles: Bool, deleteEditions: Bool) async throws -> DeleteComicOutcome {
        guard let comic else { return .shouldDismiss }
        let editions = comic.resolvedEditions
        let includeEditions = editions.count > 1 ? deleteEditions : false
        try await api.deleteComic(
            comicId: comic.id,
            deleteFiles: deleteFiles,
            deleteEditions: includeEditions
        )

        let removedIds = includeEditions ? editions.map(\.comicId) : [comic.id]
        cleanLocalContentCaches(comicIds: removedIds, modelContext: modelContext)

        if !includeEditions, editions.count > 1,
           let remaining = editions.first(where: { $0.comicId != comic.id }) {
            do {
                let reloaded = try await api.fetchComic(id: remaining.comicId)
                currentComicId = reloaded.id
                self.comic = reloaded
                return .switchedToRemainingEdition
            } catch {
                return .shouldDismiss
            }
        }
        return .shouldDismiss
    }

    private func cachedComic(id: String) -> CachedComic? {
        guard let modelContext else { return nil }
        let comicId = id
        return modelContext.fetchOrLog(
            FetchDescriptor<CachedComic>(
                predicate: #Predicate { $0.id == comicId }
            ),
            label: "加载离线漫画缓存"
        ).first
    }

    private func downloadedRecord(id: String) -> DownloadedComicRecord? {
        guard let modelContext else { return nil }
        let comicId = id
        return modelContext.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(
                predicate: #Predicate { $0.comicId == comicId }
            ),
            label: "加载离线下载类型"
        ).first
    }

    func toggleFavorite() async {
        guard let comic, !isPerformingAction else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        do {
            let resp = try await api.toggleFavorite(comicId: comic.id)
            let newFav = resp["isFavorite"] ?? !(comic.isFavorite)
            self.comic = comic.withFavorite(newFav)
            // 同步到本地缓存
            syncFavoriteToCache(comicId: comic.id, isFavorite: newFav)
            failedAction = nil
        } catch {
            AppLogger.error("收藏失败: \(error)")
            failedAction = .favorite
            actionErrorMessage = "收藏未能更新，请检查连接后重试。"
            isActionErrorPresented = true
        }
    }

    func updateReadingStatus(_ status: String?) async {
        guard let comic, !isPerformingAction else { return }
        isUpdatingReadingStatus = true
        defer { isUpdatingReadingStatus = false }
        let shouldClearFinishedProgress = comic.readingStatus == "finished" && status == nil
        let shouldMarkFinished = status == "finished" && comic.pageCount > 0
        let finishedAt = shouldMarkFinished ? Date() : nil
        do {
            try await api.updateReadingStatus(comicId: comic.id, status: status ?? "")
            var updatedComic = comic.withReadingStatus(status)
            if shouldClearFinishedProgress {
                updatedComic = updatedComic.withReadingProgress(lastReadPage: 0, lastReadAt: nil)
                syncReadingProgressToCache(comicId: comic.id, lastReadPage: 0, lastReadAt: nil, progress: 0)
            } else if shouldMarkFinished, let finishedAt {
                updatedComic = updatedComic.withReadingProgress(
                    lastReadPage: comic.pageCount - 1,
                    lastReadAt: finishedAt.iso8601String
                )
                syncReadingProgressToCache(
                    comicId: comic.id,
                    lastReadPage: comic.pageCount - 1,
                    lastReadAt: finishedAt,
                    progress: 100
                )
            }
            self.comic = updatedComic
            syncReadingStatusToCache(comicId: comic.id, status: status)
            failedAction = nil
        } catch {
            AppLogger.error("更新阅读状态失败: \(error)")
            failedAction = .readingStatus(status)
            actionErrorMessage = "阅读状态未能更新，请检查连接后重试。"
            isActionErrorPresented = true
        }
    }

    func retryFailedAction() async {
        switch failedAction {
        case .favorite: await toggleFavorite()
        case .readingStatus(let status): await updateReadingStatus(status)
        case .switchEdition(let targetComicId): await switchEdition(to: targetComicId)
        case .exportOriginalFile(let comicId, let downloadPath, let preferredFilename):
            await exportOriginalFile(
                comicId: comicId,
                downloadPath: downloadPath,
                preferredFilename: preferredFilename
            )
        case nil: break
        }
    }

    private func syncReadingStatusToCache(comicId: String, status: String?) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        guard let first = context.fetchOrLog(descriptor, label: "同步阅读状态").first else { return }
        first.readingStatus = status
        context.saveOrLog()
    }

    private func syncReadingProgressToCache(comicId: String, lastReadPage: Int, lastReadAt: Date?, progress: Int) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        guard let first = context.fetchOrLog(descriptor, label: "同步阅读进度").first else { return }
        first.lastReadPage = lastReadPage
        first.lastReadAt = lastReadAt
        first.progress = progress
        context.saveOrLog()
    }

    private func syncFavoriteToCache(comicId: String, isFavorite: Bool) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        guard let first = context.fetchOrLog(descriptor, label: "同步收藏状态").first else { return }
        first.isFavorite = isFavorite
        context.saveOrLog()
    }
}

extension Comic {
    private func copying(
        lastReadPage: Int? = nil,
        readingStatus: String?? = nil,
        lastReadAt: String?? = nil,
        isFavorite: Bool? = nil
    ) -> Comic {
        Comic(
            id: id, title: title, author: author, publisher: publisher,
            description: description, genre: genre, language: language,
            year: year, pageCount: pageCount, fileSize: fileSize,
            lastReadPage: lastReadPage ?? self.lastReadPage,
            lastReadPositionRatio: lastReadPositionRatio,
            totalReadTime: totalReadTime,
            readingStatus: readingStatus ?? self.readingStatus,
            lastReadAt: lastReadAt ?? self.lastReadAt,
            metadataSource: metadataSource, coverUrl: coverUrl,
            coverAspectRatio: coverAspectRatio, rating: rating,
            isFavorite: isFavorite ?? self.isFavorite,
            type: type, filename: filename,
            titleSortKey: titleSortKey, sortOrder: sortOrder,
            libraryId: libraryId, canManage: canManage, canDownload: canDownload,
            comicCount: comicCount, relativePath: relativePath,
            format: format, editionLabel: editionLabel,
            editionGroupId: editionGroupId, formats: formats,
            editionCount: editionCount, preferredComicId: preferredComicId,
            fileLocation: fileLocation, editions: editions,
            tags: tags, categories: categories
        )
    }

    func withReadingStatus(_ status: String?) -> Comic {
        copying(readingStatus: .some(status))
    }

    func withReadingProgress(lastReadPage: Int, lastReadAt: String?) -> Comic {
        copying(lastReadPage: lastReadPage, lastReadAt: .some(lastReadAt))
    }

    func withFavorite(_ fav: Bool) -> Comic {
        copying(isFavorite: fav)
    }
}
