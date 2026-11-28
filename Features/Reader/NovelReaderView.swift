import ImageIO
import SwiftUI
import UIKit

// MARK: - 小说阅读器（SwiftUI 入口）

struct NovelReaderView: View {
    let comicId: String
    let initialChapter: Int
    var groupContext: ReadingGroupContext? = nil

    @State private var viewModel = NovelReaderViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOverlay = false
    @State private var showChapterList = false
    @State private var showBookmarksAndNotes = false
    @State private var showSearch = false
    @State private var isApplyingCloudPreferences = false
    @State private var pendingJumpRatio: Double? = nil
    @State private var pendingSearchQuery: String? = nil
    @State private var fontSize: Double = 17
    @State private var lineSpacing: Double = 10
    @State private var letterSpacing: Double = 0
    @State private var committedFontSize: Double = 17
    @State private var committedLineSpacing: Double = 10
    @State private var committedLetterSpacing: Double = 0
    @State private var currentPage = 0
    private let recordManager: ReadingRecordManager = ReadingRecordManager.shared
    @State private var restoredChapter = -1
    @State private var repaginationAnchor: (comicId: String, chapter: Int, progress: Double)?
    @State private var loadAttempt = 0

    var body: some View {
        GeometryReader { geometry in
            let paginationSize = CGSize(
                width: max(1, geometry.size.width - 32),
                height: max(
                    1,
                    geometry.size.height
                        - geometry.safeAreaInsets.top
                        - 32
                )
            )

            ZStack {
                backgroundForTheme.ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.pages.isEmpty {
                    NovelPager(
                        pages: viewModel.pages,
                        fontSize: committedFontSize,
                        lineSpacing: committedLineSpacing,
                        letterSpacing: committedLetterSpacing,
                        darkMode: viewModel.darkMode,
                        paginationGeneration: viewModel.paginationGeneration,
                        initialPage: currentPage,
                        isPageInteractionEnabled: !showOverlay,
                        onToggleOverlay: { showOverlay.toggle() },
                        onPageChanged: { page in
                            currentPage = page
                            // 尝试追加下一章（无缝翻页）
                            viewModel.tryAppendNextChapter(currentPage: page, fontSize: committedFontSize)
                            // 检测是否已翻入下一章
                            viewModel.advanceToNextChapter(currentPage: page, fontSize: committedFontSize)

                            let chapterPages = viewModel.currentChapterPageCount()
                            let relPage = viewModel.relativePageInChapter(page)
                            let ratio = currentChapterPositionRatio(for: page)
                            viewModel.updateActivityProgress(positionRatio: ratio)

                            // 保存记录（使用相对页码与章内比例）
                            recordManager.save(
                                comicId: viewModel.currentComicId,
                                chapter: viewModel.currentChapter,
                                page: relPage,
                                totalPages: chapterPages,
                                positionRatio: ratio
                            )
                        },
                        onReachEnd: {
                            let hasNextChapter = viewModel.totalChapters > 0
                                && (viewModel.currentChapter + 1) < viewModel.totalChapters
                            let hasNextVolume = viewModel.groupContext?.nextVolumeId != nil
                            guard hasNextChapter || hasNextVolume else { return }
                            // 兜底：如果追加还没完成（或已到本卷末章需跨卷），手动切章/切卷
                            if !viewModel.nextChapterAppended || !hasNextChapter {
                                showOverlay = false
                                saveRecord()
                                restoredChapter = -1
                                currentPage = 0
                                Task { await viewModel.nextChapter(fontSize: committedFontSize) }
                            }
                        },
                        onSwipeToPrev: {
                            guard viewModel.currentChapter > 0
                                    || viewModel.groupContext?.previousVolumeId != nil else {
                                return
                            }
                            showOverlay = false
                            saveRecord()
                            restoredChapter = -1
                            currentPage = 99999
                            Task { await viewModel.prevChapter(fontSize: committedFontSize) }
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: 16) {
                        Text("无法加载正文")
                            .font(.headline)
                        Button("重试") { loadAttempt += 1 }
                            .buttonStyle(.bordered)
                        Button("返回") { dismiss() }
                    }
                    .foregroundStyle(viewModel.darkMode ? Color.white : Color.primary)
                }

                if let banner = viewModel.volumeTransitionBanner {
                    VStack {
                        Spacer()
                        Text(banner)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(viewModel.darkMode ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 28)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .task(id: loadAttempt) {
                // 从 UserDefaults 恢复排版设置（避免在 @State 初始化时产生副作用）
                let initialFont = UserDefaults.standard.double(forKey: UserDefaultsKey.novelFontSize).clamped(to: 12...30, default: 17)
                let initialLineSpacing = UserDefaults.standard.double(forKey: UserDefaultsKey.novelLineSpacing).clamped(to: 2...24, default: 10)
                let initialLetterSpacing: Double
                if let savedKern = UserDefaults.standard.object(forKey: UserDefaultsKey.novelLetterSpacing) as? Double {
                    initialLetterSpacing = savedKern.clamped(to: 0...5, default: 0)
                } else {
                    initialLetterSpacing = 0
                }
                fontSize = initialFont
                lineSpacing = initialLineSpacing
                letterSpacing = initialLetterSpacing
                committedFontSize = initialFont
                committedLineSpacing = initialLineSpacing
                committedLetterSpacing = initialLetterSpacing
                viewModel.setPaginationSize(paginationSize)
                if scenePhase == .active {
                    viewModel.resumeActivity()
                } else {
                    viewModel.pauseActivity()
                }
                // 以本地记录为准，没有记录则用 initialChapter
                let savedChapter = recordManager.load(comicId: viewModel.currentComicId.isEmpty ? comicId : viewModel.currentComicId)?.chapter ?? initialChapter
                await viewModel.load(
                    comicId: comicId,
                    chapter: savedChapter,
                    fontSize: initialFont,
                    lineSpacing: initialLineSpacing,
                    letterSpacing: initialLetterSpacing,
                    groupContext: groupContext
                )
                guard !Task.isCancelled else { return }

                let nextFont = viewModel.cloudFontSize ?? initialFont
                let nextLineSpacing = viewModel.cloudLineSpacing ?? initialLineSpacing
                let nextLetterSpacing = viewModel.cloudLetterSpacing ?? initialLetterSpacing
                let needsCloudSync = abs(nextFont - initialFont) >= 0.5
                    || abs(nextLineSpacing - initialLineSpacing) >= 0.5
                    || abs(nextLetterSpacing - initialLetterSpacing) >= 0.1

                if needsCloudSync {
                    isApplyingCloudPreferences = true
                    fontSize = nextFont
                    lineSpacing = nextLineSpacing
                    letterSpacing = nextLetterSpacing
                    committedFontSize = nextFont
                    committedLineSpacing = nextLineSpacing
                    committedLetterSpacing = nextLetterSpacing
                    UserDefaults.standard.set(nextFont, forKey: UserDefaultsKey.novelFontSize)
                    UserDefaults.standard.set(nextLineSpacing, forKey: UserDefaultsKey.novelLineSpacing)
                    UserDefaults.standard.set(nextLetterSpacing, forKey: UserDefaultsKey.novelLetterSpacing)
                    if viewModel.needsRepagination(
                        fontSize: nextFont,
                        lineSpacing: nextLineSpacing,
                        letterSpacing: nextLetterSpacing
                    ) {
                        await viewModel.repaginate(
                            fontSize: nextFont,
                            lineSpacing: nextLineSpacing,
                            letterSpacing: nextLetterSpacing
                        )
                    }
                    isApplyingCloudPreferences = false
                }
                guard !Task.isCancelled else { return }
                restorePosition()
            }
            .onDisappear {
                viewModel.pauseActivity()
                viewModel.cancelBackgroundWork()
                saveRecord()
                Task { await viewModel.finishActivity() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.resumeActivity()
                } else if newPhase == .background || newPhase == .inactive {
                    saveRecord()
                    viewModel.pauseActivity()
                    Task { await viewModel.saveProgress() }
                }
            }
            .onChange(of: paginationSize) { _, newSize in
                captureRepaginationAnchor()
                Task {
                    await viewModel.updatePaginationSize(
                        newSize,
                        fontSize: committedFontSize,
                        lineSpacing: committedLineSpacing,
                        letterSpacing: committedLetterSpacing
                    )
                }
            }
            .onChange(of: viewModel.paginationGeneration) { _, _ in
                restorePositionAfterPagination()
            }
            .onChange(of: viewModel.cloudPreferenceRevision) { _, _ in
                applyCloudPreferencesFromViewModel()
            }
            .onChange(of: viewModel.darkMode) { _, newDarkMode in
                guard !isApplyingCloudPreferences else { return }
                viewModel.scheduleSaveNovelPreferences(
                    fontSize: committedFontSize,
                    lineSpacing: committedLineSpacing,
                    letterSpacing: committedLetterSpacing,
                    darkMode: newDarkMode
                )
            }
            .overlay {
                Color.clear
                    .frame(width: max(88, geometry.size.width * 0.4))
                    .contentShape(Rectangle())
                    .onTapGesture { showOverlay.toggle() }
                    .allowsHitTesting(showOverlay && !viewModel.isLoading && !viewModel.pages.isEmpty)
            }
            .overlay {
                ReaderChrome(
                    isPresented: showOverlay || viewModel.isLoading || viewModel.pages.isEmpty
                ) {
                    topOverlay
                } footer: {
                    if !viewModel.pages.isEmpty { bottomOverlay }
                }
                .environment(\.colorScheme, viewModel.darkMode ? .dark : .light)
            }
            .sheet(isPresented: $showChapterList) {
                ChapterListView(
                    totalChapters: viewModel.totalChapters,
                    currentChapter: viewModel.currentChapter,
                    chapters: viewModel.chapterEntries,
                    chapterTitles: viewModel.chapterTitles,
                    onSelect: { index in
                        showChapterList = false
                        showOverlay = false
                        saveRecord()
                        pendingJumpRatio = nil
                        currentPage = 0
                        Task { await viewModel.load(comicId: viewModel.currentComicId, chapter: index, fontSize: committedFontSize) }
                    }
                )
            }
            .sheet(isPresented: $showBookmarksAndNotes) {
                NovelBookmarksAndNotesSheet(
                    comicTitle: viewModel.comicTitle.isEmpty ? "阅读笔记" : viewModel.comicTitle,
                    currentChapter: viewModel.currentChapter,
                    currentChapterTitle: viewModel.currentChapterDisplayTitle(),
                    currentPositionRatio: currentChapterPositionRatio(for: currentPage),
                    currentPagePreview: currentPagePreviewText(for: currentPage),
                    bookmarks: viewModel.bookmarks,
                    highlights: viewModel.highlights,
                    isBusy: viewModel.isCloudSyncBusy,
                    onJumpToLocation: { targetChapter, targetRatio in
                        showBookmarksAndNotes = false
                        showOverlay = false
                        jumpTo(chapter: targetChapter, positionRatio: targetRatio)
                    },
                    onJumpToHighlight: { highlight in
                        showBookmarksAndNotes = false
                        showOverlay = false
                        jumpTo(
                            chapter: highlight.chapterIndex,
                            positionRatio: viewModel.estimatedPositionRatio(for: highlight)
                        )
                    },
                    onUpdateBookmark: { bookmark, name, note in
                        await viewModel.updateBookmark(bookmark, name: name, note: note)
                    },
                    onDeleteBookmark: { bookmark in
                        await viewModel.deleteBookmark(bookmark)
                    },
                    onAddHighlight: { text, note, color in
                        await viewModel.addHighlight(
                            chapterIndex: viewModel.currentChapter,
                            chapterTitle: viewModel.currentChapterDisplayTitle(),
                            text: text,
                            note: note,
                            color: color
                        )
                    },
                    onUpdateHighlight: { highlight, note, color in
                        await viewModel.updateHighlight(highlight, note: note, color: color)
                    },
                    onDeleteHighlight: { highlight in
                        await viewModel.deleteHighlight(highlight)
                    },
                    onExportMarkdown: {
                        try await viewModel.exportNotesMarkdown()
                    }
                )
            }
            .sheet(isPresented: $showSearch) {
                NovelSearchSheet(
                    comicId: viewModel.currentComicId.isEmpty ? comicId : viewModel.currentComicId,
                    currentChapter: viewModel.currentChapter,
                    totalChapters: viewModel.totalChapters,
                    onOfflineFallbackSearch: { query, limit in
                        await viewModel.searchOfflineChapters(query: query, limit: limit)
                    },
                    onSelectResult: { chapterIndex, query in
                        showSearch = false
                        showOverlay = false
                        jumpToSearchResult(chapter: chapterIndex, query: query)
                    }
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
        .readerStatusBarHidden(true)
    }

    // MARK: - 恢复阅读位置

    private func captureRepaginationAnchor() {
        guard repaginationAnchor == nil, !viewModel.pages.isEmpty else { return }
        let offset = viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0
        let pageCount = viewModel.currentChapterPageCount()
        let page = min(max(currentPage - offset, 0), pageCount - 1)
        repaginationAnchor = (
            comicId: viewModel.currentComicId,
            chapter: viewModel.currentChapter,
            progress: Double(page) / Double(max(pageCount - 1, 1))
        )
    }

    private func restorePositionAfterPagination() {
        defer { repaginationAnchor = nil }
        guard let anchor = repaginationAnchor,
              anchor.comicId == viewModel.currentComicId,
              anchor.chapter == viewModel.currentChapter,
              !viewModel.pages.isEmpty else {
            restorePosition()
            return
        }

        let offset = viewModel.chapterPageOffsets[anchor.chapter] ?? 0
        let pageCount = viewModel.currentChapterPageCount()
        currentPage = offset + Int((anchor.progress * Double(pageCount - 1)).rounded())
        restoredChapter = anchor.chapter
    }

    private func restorePosition() {
        let count = viewModel.pages.count
        guard count > 0 else { return }
        currentPage = min(max(currentPage, 0), count - 1)

        let offset = viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0
        let chapterPages = viewModel.currentChapterPageCount()

        if let searchQuery = pendingSearchQuery,
           !searchQuery.isEmpty {
            let matchedPage = viewModel.pageIndex(
                matchingQuery: searchQuery,
                inChapter: viewModel.currentChapter
            ) ?? offset
            currentPage = min(max(matchedPage, 0), count - 1)
            pendingSearchQuery = nil
            pendingJumpRatio = nil
            restoredChapter = viewModel.currentChapter
            saveRecord()
            return
        }

        if let jumpRatio = pendingJumpRatio {
            let relTarget = Int((min(max(jumpRatio, 0.0), 1.0) * Double(max(1, chapterPages - 1))).rounded())
            currentPage = min(max(offset + relTarget, 0), count - 1)
            pendingJumpRatio = nil
            restoredChapter = viewModel.currentChapter
            return
        }

        guard restoredChapter != viewModel.currentChapter else { return }
        restoredChapter = viewModel.currentChapter

        if let record = recordManager.load(comicId: viewModel.currentComicId),
           record.chapter == viewModel.currentChapter {
            if record.totalPages == chapterPages,
               record.page >= 1,
               record.page <= chapterPages {
                let target = offset + record.page - 1
                currentPage = min(max(target, 0), count - 1)
            } else if let ratio = record.positionRatio {
                let relTarget = Int((ratio * Double(max(1, chapterPages - 1))).rounded())
                currentPage = min(max(offset + relTarget, 0), count - 1)
            } else {
                let relZero = max(0, record.page - 1)
                currentPage = min(max(offset + relZero, 0), count - 1)
            }
            return
        }

        if viewModel.currentChapter == initialChapter,
           let remoteRatio = viewModel.consumeRemoteInitialPositionRatio() {
            let relTarget = Int((remoteRatio * Double(max(1, chapterPages - 1))).rounded())
            currentPage = min(max(offset + relTarget, 0), count - 1)
        }
        // 无记录：保留 currentPage（前翻=0，回翻=99999→clamp 到末页）
    }

    // MARK: - 保存记录

    private func currentChapterPositionRatio(for page: Int) -> Double {
        let chapterPages = viewModel.currentChapterPageCount()
        let relPageZeroBased = max(0, viewModel.relativePageInChapter(page) - 1)
        return min(max(Double(relPageZeroBased) / Double(max(1, chapterPages - 1)), 0.0), 1.0)
    }

    private func currentPagePreviewText(for pageIndex: Int) -> String {
        guard viewModel.pages.indices.contains(pageIndex) else { return "" }
        let chunks = viewModel.pages[pageIndex].items.compactMap { item -> String? in
            if case let .text(textItem) = item {
                return textItem.text
            }
            return nil
        }
        let joined = chunks.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(120))
    }

    private func jumpTo(chapter: Int, positionRatio: Double?) {
        let safeChapter = max(0, chapter)
        let ratio = positionRatio.map { min(max($0, 0.0), 1.0) }
        if safeChapter == viewModel.currentChapter, !viewModel.pages.isEmpty {
            let offset = viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0
            let chapterPages = viewModel.currentChapterPageCount()
            let relTarget = Int(((ratio ?? 0) * Double(max(1, chapterPages - 1))).rounded())
            currentPage = min(max(offset + relTarget, 0), viewModel.pages.count - 1)
            saveRecord()
            return
        }
        saveRecord()
        pendingJumpRatio = ratio ?? 0
        restoredChapter = -1
        currentPage = 0
        Task {
            await viewModel.load(comicId: viewModel.currentComicId, chapter: safeChapter, fontSize: committedFontSize)
        }
    }

    private func jumpToSearchResult(chapter: Int, query: String) {
        let safeChapter = max(0, chapter)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingJumpRatio = nil
        if safeChapter == viewModel.currentChapter, !viewModel.pages.isEmpty {
            if !trimmedQuery.isEmpty,
               let matchedPage = viewModel.pageIndex(matchingQuery: trimmedQuery, inChapter: safeChapter) {
                currentPage = min(max(matchedPage, 0), viewModel.pages.count - 1)
            } else {
                currentPage = viewModel.chapterPageOffsets[safeChapter] ?? 0
            }
            pendingSearchQuery = nil
            saveRecord()
            return
        }
        saveRecord()
        pendingSearchQuery = trimmedQuery.isEmpty ? nil : trimmedQuery
        restoredChapter = -1
        currentPage = 0
        Task {
            await viewModel.load(
                comicId: viewModel.currentComicId,
                chapter: safeChapter,
                fontSize: committedFontSize,
                lineSpacing: committedLineSpacing,
                letterSpacing: committedLetterSpacing
            )
        }
    }

    private func applyCloudPreferencesFromViewModel() {
        isApplyingCloudPreferences = true
        defer {
            Task { @MainActor in
                isApplyingCloudPreferences = false
            }
        }
        if let cloudDark = viewModel.cloudDarkMode {
            viewModel.darkMode = cloudDark
        }
        let nextFont = viewModel.cloudFontSize ?? committedFontSize
        let nextLineSpacing = viewModel.cloudLineSpacing ?? committedLineSpacing
        let nextLetterSpacing = viewModel.cloudLetterSpacing ?? committedLetterSpacing
        let typographyChanged = abs(nextFont - committedFontSize) >= 0.5
            || abs(nextLineSpacing - committedLineSpacing) >= 0.5
            || abs(nextLetterSpacing - committedLetterSpacing) >= 0.1
        if typographyChanged, !viewModel.isLoading {
            fontSize = nextFont
            lineSpacing = nextLineSpacing
            letterSpacing = nextLetterSpacing
            committedFontSize = nextFont
            committedLineSpacing = nextLineSpacing
            committedLetterSpacing = nextLetterSpacing
            UserDefaults.standard.set(nextFont, forKey: UserDefaultsKey.novelFontSize)
            UserDefaults.standard.set(nextLineSpacing, forKey: UserDefaultsKey.novelLineSpacing)
            UserDefaults.standard.set(nextLetterSpacing, forKey: UserDefaultsKey.novelLetterSpacing)
            if viewModel.needsRepagination(
                fontSize: nextFont,
                lineSpacing: nextLineSpacing,
                letterSpacing: nextLetterSpacing
            ) {
                captureRepaginationAnchor()
                Task {
                    await viewModel.repaginate(
                        fontSize: nextFont,
                        lineSpacing: nextLineSpacing,
                        letterSpacing: nextLetterSpacing
                    )
                }
            }
        }
    }

    private func saveRecord() {
        let relPage = viewModel.relativePageInChapter(currentPage)
        let chapterPages = viewModel.currentChapterPageCount()
        let ratio = currentChapterPositionRatio(for: currentPage)
        recordManager.save(
            comicId: viewModel.currentComicId,
            chapter: viewModel.currentChapter,
            page: relPage,
            totalPages: chapterPages,
            positionRatio: ratio
        )
        viewModel.updateActivityProgress(positionRatio: ratio)
    }

    // MARK: - UI

    private var backgroundForTheme: Color {
        viewModel.darkMode ? Color(white: 0.1) : Color(uiColor: .systemBackground)
    }

    private var isCurrentPageBookmarked: Bool {
        let ratio = currentChapterPositionRatio(for: currentPage)
        return viewModel.bookmarkMatching(
            chapter: viewModel.currentChapter,
            positionRatio: ratio,
            chapterPageCount: viewModel.currentChapterPageCount()
        ) != nil
    }

    // 轻量覆盖层：闭包每次 body 求值时重建，但视图简单，不会引起可见问题
    private var topOverlay: some View {
        NovelTopOverlay(
            darkMode: viewModel.darkMode,
            currentChapter: viewModel.currentChapter,
            relativePage: viewModel.relativePageInChapter(currentPage),
            chapterPageCount: viewModel.currentChapterPageCount(),
            isCurrentPageBookmarked: isCurrentPageBookmarked,
            notesBadgeCount: viewModel.bookmarks.count + viewModel.highlights.count,
            onDismiss: { dismiss() },
            onToggleBookmark: {
                let ratio = currentChapterPositionRatio(for: currentPage)
                let relPage = viewModel.relativePageInChapter(currentPage)
                let chapterPages = viewModel.currentChapterPageCount()
                let preview = currentPagePreviewText(for: currentPage)
                Task {
                    await viewModel.toggleBookmark(
                        chapterIndex: viewModel.currentChapter,
                        positionRatio: ratio,
                        chapterTitle: viewModel.currentChapterDisplayTitle(),
                        previewText: preview,
                        relativePage: relPage,
                        chapterPageCount: chapterPages
                    )
                }
            },
            onShowSearch: {
                showSearch = true
            },
            onShowBookmarksAndNotes: {
                showBookmarksAndNotes = true
            },
            onToggleDarkMode: { viewModel.darkMode.toggle() }
        )
    }

    // 轻量覆盖层：闭包每次 body 求值时重建，但视图简单，不会引起可见问题
    private var bottomOverlay: some View {
        NovelBottomOverlay(
            fontSize: $fontSize,
            lineSpacing: $lineSpacing,
            letterSpacing: $letterSpacing,
            darkMode: viewModel.darkMode,
            isAtChapterEnd: currentPage
                >= (viewModel.chapterPageOffsets[viewModel.currentChapter] ?? 0)
                    + viewModel.currentChapterPageCount() - 1,
            hasPrevChapter: viewModel.currentChapter > 0 || viewModel.groupContext?.previousVolumeId != nil,
            onTypographyCommit: {
                committedFontSize = fontSize
                committedLineSpacing = lineSpacing
                committedLetterSpacing = letterSpacing
                UserDefaults.standard.set(committedFontSize, forKey: UserDefaultsKey.novelFontSize)
                UserDefaults.standard.set(committedLineSpacing, forKey: UserDefaultsKey.novelLineSpacing)
                UserDefaults.standard.set(committedLetterSpacing, forKey: UserDefaultsKey.novelLetterSpacing)
                if !isApplyingCloudPreferences {
                    viewModel.scheduleSaveNovelPreferences(
                        fontSize: committedFontSize,
                        lineSpacing: committedLineSpacing,
                        letterSpacing: committedLetterSpacing,
                        darkMode: viewModel.darkMode
                    )
                }
                captureRepaginationAnchor()
                Task {
                    await viewModel.repaginate(
                        fontSize: committedFontSize,
                        lineSpacing: committedLineSpacing,
                        letterSpacing: committedLetterSpacing
                    )
                }
            },
            onPrevChapter: {
                guard viewModel.currentChapter > 0
                        || viewModel.groupContext?.previousVolumeId != nil else {
                    return
                }
                showOverlay = false
                saveRecord()
                restoredChapter = -1
                currentPage = 99999
                Task { await viewModel.prevChapter(fontSize: committedFontSize) }
            },
            onNextChapter: {
                let hasNextChapter = viewModel.totalChapters > 0
                    && (viewModel.currentChapter + 1) < viewModel.totalChapters
                let hasNextVolume = viewModel.groupContext?.nextVolumeId != nil
                guard hasNextChapter || hasNextVolume else { return }
                showOverlay = false
                saveRecord()
                restoredChapter = -1
                currentPage = 0
                Task { await viewModel.nextChapter(fontSize: committedFontSize) }
            },
            onShowChapterList: { showChapterList = true }
        )
    }
}

// MARK: - 小说阅读器顶部覆盖层

struct NovelTopOverlay: View {
    let darkMode: Bool
    let currentChapter: Int
    let relativePage: Int
    let chapterPageCount: Int
    let isCurrentPageBookmarked: Bool
    let notesBadgeCount: Int
    let onDismiss: () -> Void
    let onToggleBookmark: () -> Void
    let onShowSearch: () -> Void
    let onShowBookmarksAndNotes: () -> Void
    let onToggleDarkMode: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ReaderBackButton(action: onDismiss)

            Spacer()

            VStack(spacing: 2) {
                Text("第 \(currentChapter + 1) 章")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(relativePage) / \(chapterPageCount)")
                    .font(.caption2)
                    .opacity(0.72)
            }

            Spacer()

            Button(action: onToggleBookmark) {
                Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(isCurrentPageBookmarked ? Color.yellow : (darkMode ? Color.white : Color.primary))
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrentPageBookmarked ? "取消当前页书签" : "添加当前页书签")

            Button(action: onShowSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全书搜索")

            Button(action: onShowBookmarksAndNotes) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "note.text")
                        .font(.title3)
                        .frame(width: 36, height: 44)

                    if notesBadgeCount > 0 {
                        Text("\(notesBadgeCount)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 2, y: 4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书签与笔记")

            Button(action: onToggleDarkMode) {
                Image(systemName: darkMode ? "sun.max" : "moon")
                    .font(.title3)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(darkMode ? "切换到浅色阅读" : "切换到深色阅读")
        }
        .foregroundStyle(darkMode ? Color.white : Color.primary)
    }
}

// MARK: - 小说阅读器底部覆盖层

struct NovelBottomOverlay: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var letterSpacing: Double
    let darkMode: Bool
    let isAtChapterEnd: Bool
    let hasPrevChapter: Bool
    let onTypographyCommit: () -> Void
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onShowChapterList: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("字号")
                    .font(.caption)
                    .opacity(0.8)
                    .frame(width: 32, alignment: .leading)
                Text("A").font(.caption2)
                Slider(
                    value: $fontSize,
                    in: 12...30,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            onTypographyCommit()
                        }
                    }
                )
                .tint(Color.accentColor)
                .accessibilityLabel("正文字号")
                .accessibilityValue("\(Int(fontSize))")
                Text("A").font(.headline.weight(.bold))
                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .opacity(0.75)
                    .frame(width: 32, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("行距")
                    .font(.caption)
                    .opacity(0.8)
                    .frame(width: 32, alignment: .leading)
                Slider(
                    value: $lineSpacing,
                    in: 2...24,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            onTypographyCommit()
                        }
                    }
                )
                .tint(Color.accentColor)
                .accessibilityLabel("行间距")
                .accessibilityValue("\(Int(lineSpacing)) 点")
                Text("\(Int(lineSpacing))pt")
                    .font(.caption.monospacedDigit())
                    .opacity(0.75)
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("字距")
                    .font(.caption)
                    .opacity(0.8)
                    .frame(width: 32, alignment: .leading)
                Slider(
                    value: $letterSpacing,
                    in: 0...5,
                    step: 0.5,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            onTypographyCommit()
                        }
                    }
                )
                .tint(Color.accentColor)
                .accessibilityLabel("字间距")
                .accessibilityValue(String(format: "%.1f 点", letterSpacing))
                Text(String(format: "%.1f", letterSpacing))
                    .font(.caption.monospacedDigit())
                    .opacity(0.75)
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Button(action: onPrevChapter) {
                    Label("上一章", systemImage: "chevron.left")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!hasPrevChapter)

                Spacer()

                Button(action: onShowChapterList) {
                    Label("目录", systemImage: "list.bullet")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onNextChapter) {
                    Label("下一章", systemImage: "chevron.right")
                        .font(isAtChapterEnd ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(isAtChapterEnd ? Color.accentColor : controlForeground)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(controlForeground)
    }

    private var controlForeground: Color {
        darkMode ? .white : .primary
    }
}

// MARK: - 目录弹窗

private struct ChapterListRow: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let level: Int
    let parentIndex: Int?
    let hasChildren: Bool
}

@MainActor
@Observable
private final class ChapterListModel {
    private(set) var rows: [ChapterListRow] = []
    private var rowsByIndex: [Int: ChapterListRow] = [:]

    func prepare(
        totalChapters: Int,
        chapters: [PageEntry],
        chapterTitles: [Int: String]
    ) async {
        let preparedRows = await Task.detached(priority: .userInitiated) {
            Self.makeRows(
                totalChapters: totalChapters,
                chapters: chapters,
                chapterTitles: chapterTitles
            )
        }.value
        guard !Task.isCancelled else { return }
        rowsByIndex = Dictionary(uniqueKeysWithValues: preparedRows.map { ($0.id, $0) })
        rows = preparedRows
    }

    func visibleRows(collapsedIndexes: Set<Int>) -> [ChapterListRow] {
        guard !collapsedIndexes.isEmpty else { return rows }
        return rows.filter { row in
            var parent = row.parentIndex
            var visited = Set<Int>()
            while let parentIndex = parent, visited.insert(parentIndex).inserted {
                if collapsedIndexes.contains(parentIndex) {
                    return false
                }
                parent = rowsByIndex[parentIndex]?.parentIndex
            }
            return true
        }
    }

    nonisolated private static func makeRows(
        totalChapters: Int,
        chapters: [PageEntry],
        chapterTitles: [Int: String]
    ) -> [ChapterListRow] {
        let entries: [PageEntry]
        if chapters.isEmpty {
            entries = (0..<totalChapters).map {
                PageEntry(
                    index: $0,
                    name: nil,
                    url: nil,
                    title: chapterTitles[$0],
                    level: nil,
                    parentIndex: nil,
                    hasChildren: nil
                )
            }
        } else {
            entries = chapters
        }

        var ancestors: [Int] = []
        var provisional: [(entry: PageEntry, level: Int, parent: Int?)] = []
        for entry in entries {
            let level = min(max(0, entry.level ?? 0), ancestors.count)
            while ancestors.count > level {
                ancestors.removeLast()
            }
            let inferredParent = level > 0 ? ancestors.last : nil
            let explicitParent = entry.parentIndex.flatMap { $0 >= 0 ? $0 : nil }
            provisional.append((entry, level, explicitParent ?? inferredParent))
            ancestors.append(entry.index)
        }

        let parentIndexes = Set(provisional.compactMap(\.parent))
        return provisional.enumerated().map { offset, item in
            let title = nonempty(item.entry.title)
                ?? nonempty(item.entry.name)
                ?? chapterTitles[item.entry.index]
                ?? "第 \(item.entry.index + 1) 章"
            let nextIsChild = provisional.indices.contains(offset + 1)
                && provisional[offset + 1].level > item.level
            return ChapterListRow(
                id: item.entry.index,
                title: title,
                level: item.level,
                parentIndex: item.parent,
                hasChildren: item.entry.hasChildren
                    ?? (parentIndexes.contains(item.entry.index) || nextIsChild)
            )
        }
    }

    nonisolated private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

struct ChapterListView: View {
    let totalChapters: Int
    let currentChapter: Int
    let chapters: [PageEntry]
    let chapterTitles: [Int: String]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var collapsedIndexes = Set<Int>()
    @State private var model = ChapterListModel()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if model.rows.isEmpty && totalChapters > 0 {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        ForEach(visibleRows) { row in
                            HStack(spacing: 6) {
                                if row.hasChildren {
                                    Button {
                                        toggleCollapsed(row.id)
                                    } label: {
                                        Image(
                                            systemName: collapsedIndexes.contains(row.id)
                                                ? "chevron.right"
                                                : "chevron.down"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 20, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        collapsedIndexes.contains(row.id) ? "展开" : "折叠"
                                    )
                                } else {
                                    Color.clear
                                        .frame(width: 20, height: 28)
                                        .accessibilityHidden(true)
                                }

                                Button {
                                    onSelect(row.id)
                                } label: {
                                    HStack {
                                        Text(row.title)
                                            .foregroundStyle(
                                                row.id == currentChapter
                                                    ? Color.accentColor
                                                    : .primary
                                            )
                                            .fontWeight(
                                                row.id == currentChapter
                                                    ? .semibold
                                                    : .regular
                                            )
                                            .lineLimit(2)
                                        Spacer()
                                        if row.id == currentChapter {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                                .font(.subheadline.weight(.semibold))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, CGFloat(min(row.level, 6)) * 14)
                            .id(row.id)
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentChapter)
                }
                .onChange(of: model.rows.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(currentChapter, anchor: .center)
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
        .task {
            await model.prepare(
                totalChapters: totalChapters,
                chapters: chapters,
                chapterTitles: chapterTitles
            )
        }
    }

    private var visibleRows: [ChapterListRow] {
        model.visibleRows(collapsedIndexes: collapsedIndexes)
    }

    private func toggleCollapsed(_ index: Int) {
        if collapsedIndexes.contains(index) {
            collapsedIndexes.remove(index)
        } else {
            collapsedIndexes.insert(index)
        }
    }
}

// MARK: - 翻页控制器

struct NovelPager: UIViewControllerRepresentable {
    let pages: [NovelPage]
    let fontSize: Double
    let lineSpacing: Double
    let letterSpacing: Double
    let darkMode: Bool
    let paginationGeneration: Int
    let initialPage: Int
    let isPageInteractionEnabled: Bool
    let onToggleOverlay: () -> Void
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
        pvc.view.isUserInteractionEnabled = isPageInteractionEnabled
        pvc.view.backgroundColor = pageBackgroundColor
        context.coordinator.pageViewController = pvc
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        context.coordinator.tapGesture = tap
        pvc.view.addGestureRecognizer(tap)
        disableBuiltInTapGestures(in: pvc, keeping: tap)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        pvc.view.isUserInteractionEnabled = isPageInteractionEnabled
        pvc.view.backgroundColor = pageBackgroundColor
        let coord = context.coordinator
        coord.parent = self
        coord.pageViewController = pvc
        disableBuiltInTapGestures(in: pvc, keeping: coord.tapGesture)
        guard !pages.isEmpty else { return }

        let oldCount = coord.pages.count
        let newCount = pages.count
        let renderConfiguration = Coordinator.RenderConfiguration(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            darkMode: darkMode
        )
        let configurationChanged = coord.renderConfiguration != renderConfiguration

        // 检测是否为追加（新页面以旧页面开头，仅尾部新增）
        let isAppend = newCount > oldCount
            && oldCount > 0
            && !configurationChanged
            && coord.paginationGeneration == paginationGeneration

        if isAppend {
            // 追加模式：仅更新数据源，VC 在翻页时按需懒加载
            coord.pages = pages
            // 不调用 setViewControllers，保持当前翻页位置
        } else {
            // 完全替换（切章、字号/排版变化等）
            let pagesChanged = coord.paginationGeneration != paginationGeneration

            let pageJumped = initialPage != coord.currentIndex

            if pagesChanged || configurationChanged {
                coord.rebuildCache(
                    pages: pages,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    letterSpacing: letterSpacing,
                    darkMode: darkMode
                )
                let page = min(initialPage, coord.pages.count - 1)
                if page >= 0, let targetVC = coord.viewController(at: page) {
                    pvc.setViewControllers([targetVC], direction: .forward, animated: false)
                    coord.currentIndex = page
                    coord.trimCache(around: page)
                }
            } else if pageJumped {
                let page = min(initialPage, coord.pages.count - 1)
                if page >= 0, let targetVC = coord.viewController(at: page) {
                    pvc.setViewControllers([targetVC], direction: .forward, animated: false)
                    coord.currentIndex = page
                    coord.trimCache(around: page)
                }
            }
        }
    }

    private var pageBackgroundColor: UIColor {
        darkMode ? UIColor(white: 0.1, alpha: 1) : .systemBackground
    }

    private func disableBuiltInTapGestures(
        in pvc: UIPageViewController,
        keeping tapGesture: UITapGestureRecognizer?
    ) {
        for recognizer in pvc.view.gestureRecognizers ?? []
        where recognizer is UITapGestureRecognizer && recognizer !== tapGesture {
            recognizer.isEnabled = false
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: NovelPager
        weak var pageViewController: UIPageViewController?
        weak var tapGesture: UITapGestureRecognizer?
        var pages: [NovelPage] = []
        private var vcCache: [Int: NovelTextPageVC] = [:]
        var currentIndex: Int = 0
        var paginationGeneration = -1
        var renderConfiguration: RenderConfiguration?

        struct RenderConfiguration: Equatable {
            let fontSize: Double
            let lineSpacing: Double
            let letterSpacing: Double
            let darkMode: Bool
        }

        init(_ parent: NovelPager) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, view.bounds.width > 0 else { return }
            let point = gesture.location(in: view)
            let width = view.bounds.width
            if point.x < width * 0.3 {
                if let pvc = pageViewController {
                    turnToPreviousPage(in: pvc)
                }
            } else if point.x > width * 0.7 {
                if let pvc = pageViewController {
                    turnToNextPage(in: pvc)
                }
            } else {
                parent.onToggleOverlay()
            }
        }

        func viewController(at index: Int) -> NovelTextPageVC? {
            guard pages.indices.contains(index) else { return nil }
            if let cached = vcCache[index] {
                return cached
            }
            let config = renderConfiguration ?? RenderConfiguration(
                fontSize: parent.fontSize,
                lineSpacing: parent.lineSpacing,
                letterSpacing: parent.letterSpacing,
                darkMode: parent.darkMode
            )
            let vc = NovelTextPageVC(
                page: pages[index],
                index: index,
                fontSize: config.fontSize,
                lineSpacing: config.lineSpacing,
                letterSpacing: config.letterSpacing,
                darkMode: config.darkMode
            )
            vcCache[index] = vc
            trimCache(around: currentIndex, keeping: index)
            return vc
        }

        func trimCache(around center: Int, keeping extraIndex: Int? = nil) {
            guard vcCache.count > 7 else { return }
            for key in Array(vcCache.keys) {
                if key == center || key == extraIndex { continue }
                if abs(key - center) > 3 {
                    vcCache.removeValue(forKey: key)
                }
            }
        }

        private func turnToPreviousPage(in pvc: UIPageViewController) {
            guard !pages.isEmpty else { return }
            let prev = currentIndex - 1
            if prev < 0 {
                DispatchQueue.main.async { self.parent.onSwipeToPrev() }
                return
            }
            guard let targetVC = viewController(at: prev) else { return }
            currentIndex = prev
            trimCache(around: prev)
            pvc.setViewControllers([targetVC], direction: .reverse, animated: true) { [weak self] _ in
                self?.parent.onPageChanged(prev)
            }
        }

        private func turnToNextPage(in pvc: UIPageViewController) {
            guard !pages.isEmpty else { return }
            let next = currentIndex + 1
            if next >= pages.count {
                DispatchQueue.main.async { self.parent.onReachEnd() }
                return
            }
            guard let targetVC = viewController(at: next) else { return }
            currentIndex = next
            trimCache(around: next)
            pvc.setViewControllers([targetVC], direction: .forward, animated: true) { [weak self] _ in
                self?.parent.onPageChanged(next)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let target = touchedView {
                // 插图保留自己的放大手势；工具栏由 SwiftUI 接收操作。
                if target is UIControl || target is UIImageView { return false }
                touchedView = target.superview
            }
            return true
        }

        func rebuildCache(
            pages: [NovelPage],
            fontSize: Double,
            lineSpacing: Double,
            letterSpacing: Double,
            darkMode: Bool
        ) {
            paginationGeneration = parent.paginationGeneration
            renderConfiguration = RenderConfiguration(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                darkMode: darkMode
            )
            self.pages = pages
            vcCache.removeAll()
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? NovelTextPageVC else { return nil }
            let prev = page.index - 1
            if prev < 0 {
                DispatchQueue.main.async { self.parent.onSwipeToPrev() }
                return nil
            }
            return self.viewController(at: prev)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? NovelTextPageVC else { return nil }
            let next = page.index + 1
            if next >= pages.count {
                DispatchQueue.main.async { self.parent.onReachEnd() }
                return nil
            }
            return self.viewController(at: next)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? NovelTextPageVC else { return }
            currentIndex = current.index
            trimCache(around: current.index)
            parent.onPageChanged(current.index)
        }
    }
}

// MARK: - 单页 VC

class NovelTextPageVC: UIViewController {
    let page: NovelPage
    let index: Int
    let fontSize: Double
    let lineSpacing: Double
    let letterSpacing: Double
    let darkMode: Bool
    private var imageLoadTasks: [Task<Void, Never>] = []

    init(
        page: NovelPage,
        index: Int,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        darkMode: Bool
    ) {
        self.page = page
        self.index = index
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        self.darkMode = darkMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageLoadTasks.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = darkMode ? UIColor(white: 0.1, alpha: 1) : .systemBackground

        let textColor: UIColor = darkMode ? .white.withAlphaComponent(0.9) : .label
        let contentView = UIView()
        contentView.backgroundColor = .clear
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            ),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        for item in page.items {
            switch item {
            case let .text(textItem):
                addTextItem(textItem, color: textColor, to: contentView)
            case let .image(imageItem):
                addImageItem(imageItem, to: contentView)
            }
        }
    }

    private func addTextItem(
        _ item: NovelTextPageItem,
        color: UIColor,
        to contentView: UIView
    ) {
        let label = UILabel()
        label.numberOfLines = 0
        label.backgroundColor = .clear
        label.attributedText = NSAttributedString(
            string: item.text,
            attributes: PaginationService.attributes(
                style: item.style,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                textColor: color
            )
        )
        add(
            label,
            frame: item.frame.cgRect,
            to: contentView
        )
    }

    private func addImageItem(
        _ item: NovelImagePageItem,
        to contentView: UIView
    ) {
        guard let data = item.data else {
            let placeholder = NovelImagePlaceholderView(altText: item.altText)
            add(placeholder, frame: item.frame.cgRect, to: contentView)
            return
        }

        let displayScale = max(1, traitCollection.displayScale)
        let maxPixelSize = max(1, max(item.frame.width, item.frame.height) * displayScale)
        let thumbKey = "novel-thumb:\(item.source):\(Int(maxPixelSize.rounded()))"

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = item.altText ?? "小说插图"
        imageView.accessibilityTraits = .image
        let tap = UITapGestureRecognizer(target: self, action: #selector(openImage(_:)))
        imageView.addGestureRecognizer(tap)
        add(imageView, frame: item.frame.cgRect, to: contentView)

        if let cached = ImageCache.shared.memoryImage(forKey: thumbKey) {
            imageView.image = cached
            return
        }

        let task = Task { [weak self, weak imageView] in
            let decoded = await Self.decodeDownsampledImage(
                data: data,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled, let self, let imageView else { return }
            if let decoded {
                ImageCache.shared.setMemoryOnly(decoded, forKey: thumbKey)
                imageView.image = decoded
            } else {
                let placeholder = NovelImagePlaceholderView(altText: item.altText)
                self.add(placeholder, frame: item.frame.cgRect, to: contentView)
                imageView.removeFromSuperview()
            }
        }
        imageLoadTasks.append(task)
    }

    private static func decodeDownsampledImage(
        data: Data,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        let decodeTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) {
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbOptions as CFDictionary
                ) {
                    return UIImage(cgImage: cgImage)
                }
            }
            guard !Task.isCancelled, let raw = UIImage(data: data) else { return nil }
            return raw.preparingForDisplay() ?? raw
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    private func add(_ child: UIView, frame: CGRect, to contentView: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: frame.minX
            ),
            child.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: frame.minY
            ),
            child.widthAnchor.constraint(equalToConstant: frame.width),
            child.heightAnchor.constraint(equalToConstant: frame.height),
        ])
    }

    @objc private func openImage(_ recognizer: UITapGestureRecognizer) {
        guard let imageView = recognizer.view as? UIImageView,
              let image = imageView.image else {
            return
        }
        present(NovelImageViewerController(image: image), animated: true)
    }
}

private final class NovelImagePlaceholderView: UIView {
    init(altText: String?) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 6

        let icon = UIImageView(image: UIImage(systemName: "photo"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = altText?.isEmpty == false ? altText : "图片暂时无法显示"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class NovelImageViewerController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let closeButton = UIButton(type: .close)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollView.zoomScale == 1 else { return }
        let bounds = scrollView.bounds.size
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(
            width: image.size.width * ratio,
            height: image.size.height * ratio
        )
        imageView.frame = CGRect(
            x: max(0, (bounds.width - fitted.width) / 2),
            y: max(0, (bounds.height - fitted.height) / 2),
            width: fitted.width,
            height: fitted.height
        )
        scrollView.contentSize = bounds
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let novelChapterCacheClear = Notification.Name("novelChapterCacheClear")
}

// MARK: - ViewModel

@MainActor
@Observable
final class NovelReaderViewModel {
    var chapterContent: ChapterContent?
    var isLoading = true
    var currentChapter = 0
    var totalChapters: Int = 0
    var darkMode = false
    var pages: [NovelPage] = []
    var groupContext: ReadingGroupContext?
    var volumeTransitionBanner: String?
    var currentComicId: String
    var chapterTitles: [Int: String] = [:]
    var chapterEntries: [PageEntry] = []
    private(set) var paginationGeneration = 0

    // MARK: - 云端同步状态（Phase 2 & 3）
    var comicTitle = ""
    var bookmarks: [UserBookmark] = []
    var highlights: [UserHighlight] = []
    var cloudFontSize: Double?
    var cloudLineSpacing: Double?
    var cloudLetterSpacing: Double?
    var cloudDarkMode: Bool?
    var cloudPreferenceRevision = 0
    var isCloudSyncBusy = false

    /// 各章节的起始页索引 [章节号: 在 pages 中的起始位置]
    private(set) var chapterPageOffsets: [Int: Int] = [:]
    /// 下一章页面是否已追加
    private(set) var nextChapterAppended = false

    private var comicId = ""
    private var isSwitchingVolume = false
    private var typographyLineSpacing: Double = 10
    private var typographyLetterSpacing: Double = 0
    private let api = APIClient.shared
    private let cache = ChapterCache()
    private var activityTracker: ReadingActivityTracker?
    private var isReaderActive = true
    private var remoteInitialPositionRatio: Double?
    private var hasConsumedRemoteRatio = false
    private var loadedCloudComicId = ""
    private var cachedGlobalNovelPrefs: [String: ReaderPreferenceValue] = [:]
    @ObservationIgnored private var prefSaveTask: Task<Void, Never>?
    @ObservationIgnored private var cacheObserver: Any?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?
    @ObservationIgnored private var appendPaginationTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastPaginatedTypography: (fontSize: Double, lineSpacing: Double, letterSpacing: Double)?
    private var paginationRequestID = UUID()
    private var appendPaginationRequestID: UUID?
    private var appendedChapterContent: ChapterContent?
    private var paginationSize = CGSize(width: 320, height: 640)

    private nonisolated static let searchWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

    init() {
        self.currentComicId = ""
        cacheObserver = NotificationCenter.default.addObserver(
            forName: .novelChapterCacheClear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cache.clear()
            }
        }
    }

    deinit {
        if let observer = cacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        paginationTask?.cancel()
        appendPaginationTask?.cancel()
        bannerTask?.cancel()
        prefSaveTask?.cancel()
    }

    func cancelBackgroundWork() {
        paginationTask?.cancel()
        appendPaginationTask?.cancel()
        bannerTask?.cancel()
        cache.cancelPreloads()
    }

    func needsRepagination(
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double
    ) -> Bool {
        guard let last = lastPaginatedTypography else { return true }
        return abs(last.fontSize - fontSize) >= 0.5
            || abs(last.lineSpacing - lineSpacing) >= 0.5
            || abs(last.letterSpacing - letterSpacing) >= 0.1
    }

    // MARK: - 分页尺寸

    func setPaginationSize(_ size: CGSize) {
        paginationSize = normalizedPaginationSize(size)
    }

    func updatePaginationSize(
        _ size: CGSize,
        fontSize: Double,
        lineSpacing: Double? = nil,
        letterSpacing: Double? = nil
    ) async {
        let normalized = normalizedPaginationSize(size)
        guard abs(normalized.width - paginationSize.width) > 0.5
                || abs(normalized.height - paginationSize.height) > 0.5 else {
            return
        }
        paginationSize = normalized
        guard chapterContent != nil else { return }
        await repaginate(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
    }

    private func normalizedPaginationSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    // MARK: - 缓存便捷方法

    private func applyFromCache(
        chapter: Int,
        fontSize: Double,
        lineSpacing: Double? = nil,
        letterSpacing: Double? = nil
    ) async -> Bool {
        guard let cached = cache.get(chapter) else { return false }
        isLoading = true
        chapterContent = cached
        currentChapter = chapter
        chapterTitles = cache.chapterTitles
        chapterEntries = cache.chapterEntries
        await repaginate(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
        guard !Task.isCancelled else { return false }
        updateActivityProgress()
        isLoading = false
        return true
    }

    // MARK: - 加载

    func load(
        comicId: String,
        chapter: Int,
        fontSize: Double = 17,
        lineSpacing: Double? = nil,
        letterSpacing: Double? = nil,
        groupContext: ReadingGroupContext? = nil
    ) async {
        if let lineSpacing { typographyLineSpacing = lineSpacing }
        if let letterSpacing { typographyLetterSpacing = letterSpacing }
        let isSwitchingComic = !currentComicId.isEmpty && currentComicId != comicId
        if isSwitchingComic {
            await finishActivity()
            cache.clear()
            chapterTitles = [:]
            chapterEntries = []
            totalChapters = 0
            bookmarks = []
            highlights = []
            comicTitle = ""
            remoteInitialPositionRatio = nil
            hasConsumedRemoteRatio = false
            loadedCloudComicId = ""
        }
        self.comicId = comicId
        self.currentComicId = comicId
        if let groupContext {
            self.groupContext = groupContext
        }

        async let cloudSyncTask: Void = loadCloudSyncDataIfNeeded(for: comicId)

        if await applyFromCache(chapter: chapter, fontSize: fontSize) {
            await cloudSyncTask
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        guard !Task.isCancelled else { return }

        self.currentChapter = chapter
        isLoading = true
        do {
            chapterContent = try await loadChapterContent(
                comicId: comicId,
                index: chapter
            )
            guard !Task.isCancelled else { return }
            if let content = chapterContent {
                cache.put(content, for: chapter)
            }
            if let t = chapterContent?.totalChapters {
                totalChapters = t
            }
            if totalChapters == 0 || cache.chapterEntries.isEmpty {
                if let pageList = await loadPageList(comicId: comicId) {
                    totalChapters = pageList.totalPages
                    if comicTitle.isEmpty, let title = pageList.title {
                        comicTitle = title
                    }
                    cache.extractTitles(from: pageList)
                    chapterTitles = cache.chapterTitles
                    chapterEntries = cache.chapterEntries
                }
            }
            cache.evict(keeping: chapter)
            await cloudSyncTask
            guard !Task.isCancelled else { return }
            let effectiveFontSize = cloudFontSize ?? fontSize
            let effectiveLineSpacing = cloudLineSpacing ?? typographyLineSpacing
            let effectiveLetterSpacing = cloudLetterSpacing ?? typographyLetterSpacing
            await repaginate(
                fontSize: effectiveFontSize,
                lineSpacing: effectiveLineSpacing,
                letterSpacing: effectiveLetterSpacing
            )
            guard !Task.isCancelled else { return }
            updateActivityProgress()
        } catch {
            await cloudSyncTask
            guard !Task.isCancelled else { return }
            AppLogger.error("加载章节失败: \(error)")
        }
        isLoading = false

        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    func loadVolume(comicId: String, chapter: Int, fontSize: Double = 17) async {
        guard !isSwitchingVolume else { return }
        isSwitchingVolume = true
        defer { isSwitchingVolume = false }

        let previousIndex = groupContext?.currentIndex
        await finishActivity()

        bannerTask?.cancel()
        volumeTransitionBanner = nil

        var transitionText: String?
        if let ctx = groupContext,
           let newIdx = ctx.volumeIds.firstIndex(of: comicId) {
            groupContext = ReadingGroupContext(
                groupId: ctx.groupId,
                volumeIds: ctx.volumeIds,
                currentIndex: newIdx
            )
            if let previousIndex {
                if newIdx > previousIndex {
                    transitionText = "已进入下一卷（卷 \(newIdx + 1)/\(ctx.volumeIds.count)）"
                } else if newIdx < previousIndex {
                    transitionText = "已返回上一卷（卷 \(newIdx + 1)/\(ctx.volumeIds.count)）"
                }
            }
        }

        self.comicId = comicId
        self.currentComicId = comicId
        self.currentChapter = chapter
        self.bookmarks = []
        self.highlights = []
        self.comicTitle = ""
        self.remoteInitialPositionRatio = nil
        self.hasConsumedRemoteRatio = false
        self.loadedCloudComicId = ""
        isLoading = true
        cache.clear()

        async let cloudSyncTask: Void = loadCloudSyncDataIfNeeded(for: comicId)

        do {
            guard let pageList = await loadPageList(comicId: comicId) else {
                throw APIError.dataFormat
            }
            self.totalChapters = max(1, pageList.totalPages)
            if let title = pageList.title, !title.isEmpty {
                comicTitle = title
            }
            cache.extractTitles(from: pageList)
            chapterTitles = cache.chapterTitles
            chapterEntries = cache.chapterEntries
            let safeChapter = min(chapter, self.totalChapters - 1)
            chapterContent = try await loadChapterContent(
                comicId: comicId,
                index: safeChapter
            )
            if let content = chapterContent {
                cache.put(content, for: safeChapter)
            }
            currentChapter = safeChapter
            await cloudSyncTask
            let effectiveFontSize = cloudFontSize ?? fontSize
            let effectiveLineSpacing = cloudLineSpacing ?? typographyLineSpacing
            let effectiveLetterSpacing = cloudLetterSpacing ?? typographyLetterSpacing
            await repaginate(
                fontSize: effectiveFontSize,
                lineSpacing: effectiveLineSpacing,
                letterSpacing: effectiveLetterSpacing
            )
            updateActivityProgress()
        } catch {
            await cloudSyncTask
            AppLogger.error("加载卷失败: \(error)")
        }
        isLoading = false

        if let transitionText, !pages.isEmpty {
            showVolumeTransitionBanner(transitionText)
        }

        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    private func showVolumeTransitionBanner(_ message: String) {
        bannerTask?.cancel()
        volumeTransitionBanner = message
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            self?.volumeTransitionBanner = nil
        }
    }

    func nextChapter(fontSize: Double = 17) async {
        let nextIndex = currentChapter + 1
        if totalChapters > 0 && nextIndex >= totalChapters {
            guard let nextId = groupContext?.nextVolumeId else { return }
            updateActivityProgress(positionRatio: 1.0)
            await loadVolume(comicId: nextId, chapter: 0, fontSize: fontSize)
            return
        }
        if await applyFromCache(chapter: nextIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: nextIndex, fontSize: fontSize)
    }

    func prevChapter(fontSize: Double = 17) async {
        guard currentChapter > 0 else {
            guard let prevId = groupContext?.previousVolumeId else { return }
            if let pageList = await loadPageList(comicId: prevId) {
                let lastChapter = max(0, pageList.totalPages - 1)
                await loadVolume(comicId: prevId, chapter: lastChapter, fontSize: fontSize)
            }
            return
        }
        let prevIndex = currentChapter - 1
        if await applyFromCache(chapter: prevIndex, fontSize: fontSize) {
            cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
            return
        }
        await load(comicId: comicId, chapter: prevIndex, fontSize: fontSize)
    }

    func saveProgress(currentPage: Int = 0) async {
        updateActivityProgress()
        do {
            try await activityTracker?.flush(finalize: false)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
    }

    func finishActivity() async {
        updateActivityProgress()
        do {
            try await activityTracker?.flush(finalize: true)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
        activityTracker = nil
    }

    func pauseActivity() {
        isReaderActive = false
        activityTracker?.setActive(false)
    }

    func resumeActivity() {
        isReaderActive = true
        activityTracker?.setActive(true)
    }

    func updateActivityProgress(positionRatio: Double? = nil) {
        guard totalChapters > 0, !currentComicId.isEmpty else { return }
        let safeChapter = min(max(currentChapter, 0), max(totalChapters - 1, 0))
        if activityTracker?.comicId != currentComicId {
            activityTracker = ReadingActivityTracker(comicId: currentComicId)
            activityTracker?.start(
                page: safeChapter,
                totalPages: totalChapters,
                positionRatio: positionRatio,
                isActive: isReaderActive
            )
        } else {
            activityTracker?.updatePage(
                page: safeChapter,
                totalPages: totalChapters,
                positionRatio: positionRatio
            )
        }
    }

    // MARK: - 云端书签、批注与偏好（Phase 2）

    func currentChapterDisplayTitle() -> String {
        if let mapped = chapterTitles[currentChapter]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty {
            return mapped
        }
        if let entry = chapterEntries.first(where: { $0.index == currentChapter }),
           let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let title = chapterContent?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "第 \(currentChapter + 1) 章"
    }

    func consumeRemoteInitialPositionRatio() -> Double? {
        guard !hasConsumedRemoteRatio, let ratio = remoteInitialPositionRatio else {
            return nil
        }
        hasConsumedRemoteRatio = true
        return ratio
    }

    func bookmarkMatching(
        chapter: Int,
        positionRatio: Double,
        chapterPageCount: Int
    ) -> UserBookmark? {
        let tolerance = chapterPageCount > 1
            ? (0.5 / Double(chapterPageCount - 1))
            : 0.5
        return bookmarks.first { bookmark in
            bookmark.pageIndex == chapter
                && abs(bookmark.positionRatio - positionRatio) <= tolerance
        }
    }

    func toggleBookmark(
        chapterIndex: Int,
        positionRatio: Double,
        chapterTitle: String,
        previewText: String,
        relativePage: Int,
        chapterPageCount: Int
    ) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        if let existing = bookmarkMatching(
            chapter: chapterIndex,
            positionRatio: positionRatio,
            chapterPageCount: chapterPageCount
        ) {
            await deleteBookmark(existing)
            return
        }

        let trimmedPreview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = trimmedPreview.isEmpty
            ? "\(chapterTitle) · 第 \(relativePage) 页"
            : String(trimmedPreview.prefix(24))

        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            let created = try await api.upsertBookmark(
                comicId: currentComicId,
                pageIndex: chapterIndex,
                positionRatio: positionRatio,
                chapterTitle: chapterTitle,
                name: defaultName,
                note: ""
            )
            bookmarks.removeAll { $0.id == created.id }
            bookmarks.append(created)
            bookmarks.sort {
                if $0.pageIndex != $1.pageIndex {
                    return $0.pageIndex < $1.pageIndex
                }
                return $0.positionRatio < $1.positionRatio
            }
        } catch {
            AppLogger.error("保存小说书签失败: \(error.localizedDescription)")
        }
    }

    func updateBookmark(_ bookmark: UserBookmark, name: String, note: String) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            let updated = try await api.updateBookmark(
                comicId: currentComicId,
                bookmarkId: bookmark.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if let index = bookmarks.firstIndex(where: { $0.id == updated.id }) {
                bookmarks[index] = updated
            }
        } catch {
            AppLogger.error("更新小说书签失败: \(error.localizedDescription)")
        }
    }

    func deleteBookmark(_ bookmark: UserBookmark) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            try await api.deleteBookmark(comicId: currentComicId, bookmarkId: bookmark.id)
            bookmarks.removeAll { $0.id == bookmark.id }
        } catch {
            AppLogger.error("删除小说书签失败: \(error.localizedDescription)")
        }
    }

    func addHighlight(
        chapterIndex: Int,
        chapterTitle: String,
        text: String,
        note: String,
        color: String
    ) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentComicId.isEmpty, !trimmedText.isEmpty,
              api.isNetworkReachable, !api.isOfflineMode else { return }
        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            let created = try await api.upsertHighlight(
                comicId: currentComicId,
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                text: trimmedText,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                color: color,
                startOffset: -1
            )
            highlights.removeAll { $0.id == created.id }
            highlights.append(created)
            highlights.sort {
                if $0.chapterIndex != $1.chapterIndex {
                    return $0.chapterIndex < $1.chapterIndex
                }
                return $0.createdAt < $1.createdAt
            }
        } catch {
            AppLogger.error("保存划线批注失败: \(error.localizedDescription)")
        }
    }

    func updateHighlight(_ highlight: UserHighlight, note: String, color: String) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            let updated = try await api.updateHighlight(
                comicId: currentComicId,
                highlightId: highlight.id,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                color: color
            )
            if let index = highlights.firstIndex(where: { $0.id == updated.id }) {
                highlights[index] = updated
            }
        } catch {
            AppLogger.error("更新划线批注失败: \(error.localizedDescription)")
        }
    }

    func deleteHighlight(_ highlight: UserHighlight) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        isCloudSyncBusy = true
        defer { isCloudSyncBusy = false }
        do {
            try await api.deleteHighlight(comicId: currentComicId, highlightId: highlight.id)
            highlights.removeAll { $0.id == highlight.id }
        } catch {
            AppLogger.error("删除划线批注失败: \(error.localizedDescription)")
        }
    }

    func exportNotesMarkdown() async throws -> URL {
        try await api.exportHighlightsMarkdown(
            comicId: currentComicId,
            preferredTitle: comicTitle.isEmpty ? nil : comicTitle
        )
    }

    func estimatedPositionRatio(for highlight: UserHighlight) -> Double? {
        guard let cached = cache.get(highlight.chapterIndex)?.content,
              !cached.isEmpty else {
            return nil
        }
        let trimmed = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let range = cached.range(of: trimmed) {
            let offset = cached.distance(from: cached.startIndex, to: range.lowerBound)
            let total = max(1, cached.count)
            return min(max(Double(offset) / Double(total), 0.0), 1.0)
        }
        if highlight.startOffset >= 0 {
            let total = max(1, cached.count)
            return min(max(Double(highlight.startOffset) / Double(total), 0.0), 1.0)
        }
        return nil
    }

    func scheduleSaveNovelPreferences(
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        darkMode: Bool
    ) {
        guard api.isNetworkReachable, !api.isOfflineMode else { return }
        prefSaveTask?.cancel()
        prefSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            var payload = self.cachedGlobalNovelPrefs
            payload["fontSize"] = .double(fontSize)
            payload["lineSpacing"] = .double(lineSpacing)
            let lineHeightRatio = max(1.0, ((fontSize + lineSpacing) / max(12.0, fontSize) * 10).rounded() / 10)
            payload["lineHeight"] = .double(lineHeightRatio)
            payload["letterSpacing"] = .double(letterSpacing)
            payload["darkMode"] = .bool(darkMode)
            payload["theme"] = .string(darkMode ? "night" : "day")
            self.cachedGlobalNovelPrefs = payload
            do {
                try await self.api.saveReaderPreference(scope: "global_novel", prefs: payload)
            } catch {
                AppLogger.log("同步小说云端偏好失败: \(error.localizedDescription)")
            }
        }
    }

    /// 离线模式下对本地已缓存章节执行全书检索降级扫描
    func searchOfflineChapters(query: String, limit: Int = 100) async -> NovelSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, totalChapters > 0 else {
            return NovelSearchResponse(
                query: trimmed,
                totalChapters: totalChapters,
                matchedChapters: 0,
                totalMatches: 0,
                truncated: false,
                results: []
            )
        }

        let targetComicId = currentComicId.isEmpty ? comicId : currentComicId
        let chaptersCount = totalChapters
        let titlesSnapshot = chapterTitles
        let entryTitles = Dictionary(
            chapterEntries.compactMap { entry -> (Int, String)? in
                guard let title = entry.title, !title.isEmpty else { return nil }
                return (entry.index, title)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var cachedRawByIndex: [Int: (title: String, content: String, mimeType: String?)] = [:]
        for idx in 0..<chaptersCount {
            if let cached = cache.get(idx), let raw = cached.content, !raw.isEmpty {
                let title = titlesSnapshot[idx]
                    ?? entryTitles[idx]
                    ?? cached.title
                    ?? "第 \(idx + 1) 章"
                cachedRawByIndex[idx] = (title, raw, cached.mimeType)
            }
        }

        let searchTask = Task.detached(priority: .userInitiated) { () -> NovelSearchResponse in
            let offlineManager = OfflineFileManager.shared
            var items: [NovelSearchResultItem] = []
            var totalMatches = 0
            var truncated = false

            for idx in 0..<chaptersCount {
                if Task.isCancelled { break }
                let plainText: String
                let title: String
                if let memMatch = cachedRawByIndex[idx] {
                    title = memMatch.title
                    plainText = PaginationService.readableText(
                        content: memMatch.content,
                        mimeType: memMatch.mimeType
                    )
                } else if let local = offlineManager.loadNovelChapter(comicId: targetComicId, chapter: idx),
                          let raw = local.content,
                          !raw.isEmpty {
                    title = titlesSnapshot[idx]
                        ?? entryTitles[idx]
                        ?? local.title
                        ?? "第 \(idx + 1) 章"
                    plainText = PaginationService.readableText(
                        content: raw,
                        mimeType: local.mimeType
                    )
                } else {
                    continue
                }

                var matchCount = 0
                var firstRange: Range<String.Index>?
                var searchStart = plainText.startIndex
                while searchStart < plainText.endIndex,
                      let found = plainText.range(
                        of: trimmed,
                        options: [.caseInsensitive],
                        range: searchStart..<plainText.endIndex
                      ) {
                    if firstRange == nil { firstRange = found }
                    matchCount += 1
                    searchStart = found.upperBound
                }
                guard matchCount > 0, let firstRange else { continue }

                if items.count >= limit {
                    truncated = true
                    break
                }

                let snippetStart = plainText.index(
                    firstRange.lowerBound,
                    offsetBy: -24,
                    limitedBy: plainText.startIndex
                ) ?? plainText.startIndex
                let snippetEnd = plainText.index(
                    firstRange.upperBound,
                    offsetBy: 36,
                    limitedBy: plainText.endIndex
                ) ?? plainText.endIndex
                let rawSlice = String(plainText[snippetStart..<snippetEnd])
                let mutableSnippet = NSMutableString(string: rawSlice)
                Self.searchWhitespaceRegex.replaceMatches(
                    in: mutableSnippet,
                    range: NSRange(location: 0, length: mutableSnippet.length),
                    withTemplate: " "
                )
                let snippetRaw = (mutableSnippet as String)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = snippetStart > plainText.startIndex ? "..." : ""
                let suffix = snippetEnd < plainText.endIndex ? "..." : ""

                totalMatches += matchCount
                items.append(NovelSearchResultItem(
                    chapterIndex: idx,
                    chapterTitle: title,
                    matchText: "\(prefix)\(snippetRaw)\(suffix)",
                    matchCount: matchCount
                ))
            }

            return NovelSearchResponse(
                query: trimmed,
                totalChapters: chaptersCount,
                matchedChapters: items.count,
                totalMatches: totalMatches,
                truncated: truncated,
                results: items
            )
        }
        return await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
    }

    /// 在指定章节的分页结果中查找包含关键词的目标页码（用于搜索跳转精确定位）
    func pageIndex(matchingQuery query: String, inChapter chapter: Int) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !pages.isEmpty else { return nil }

        let start = max(0, chapterPageOffsets[chapter] ?? 0)
        let end = min(pages.count, chapterPageOffsets[chapter + 1] ?? pages.count)
        guard start < end else { return nil }

        for index in start..<end {
            let pageText = pages[index].items.compactMap { item -> String? in
                if case let .text(textItem) = item { return textItem.text }
                return nil
            }.joined(separator: "\n")
            if pageText.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return index
            }
        }

        // 若关键词恰好跨空白/换行断开，去除空白后匹配
        let compactQuery = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        if !compactQuery.isEmpty {
            for index in start..<end {
                let pageCompact = pages[index].items.compactMap { item -> String? in
                    if case let .text(textItem) = item { return textItem.text }
                    return nil
                }.joined().components(separatedBy: .whitespacesAndNewlines).joined()
                if pageCompact.range(of: compactQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    return index
                }
            }
        }

        // 最后回退到章节纯文本偏移比例定位
        if let raw = chapterContent?.content {
            let plain = PaginationService.readableText(content: raw, mimeType: chapterContent?.mimeType)
            if let range = plain.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
                let charOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let ratio = Double(charOffset) / Double(max(1, plain.count))
                let chapterCount = max(1, end - start)
                return min(end - 1, start + Int((ratio * Double(max(0, chapterCount - 1))).rounded()))
            }
        }
        return nil
    }

    private func loadCloudSyncDataIfNeeded(for targetComicId: String) async {
        guard loadedCloudComicId != targetComicId, !targetComicId.isEmpty else { return }
        loadedCloudComicId = targetComicId

        if !api.isNetworkReachable || api.isOfflineMode {
            if groupContext == nil,
               let resolved = await api.resolveReadingGroupContext(
                   for: targetComicId,
                   libraryId: nil,
                   relativePath: nil
               ),
               !Task.isCancelled,
               targetComicId == currentComicId {
                groupContext = resolved.context
            }
            return
        }

        async let comicTask: Comic? = try? api.fetchComic(id: targetComicId)
        async let bookmarksTask: [UserBookmark]? = try? api.fetchBookmarks(comicId: targetComicId)
        async let highlightsTask: [UserHighlight]? = try? api.fetchHighlights(comicId: targetComicId)
        async let prefsTask: ScopedReaderPreferences? = try? api.fetchReaderPreferences(comicId: targetComicId)

        let (remoteComic, remoteBookmarks, remoteHighlights, remotePrefs) = await (
            comicTask, bookmarksTask, highlightsTask, prefsTask
        )
        guard !Task.isCancelled, targetComicId == currentComicId else { return }

        if let remoteComic {
            if comicTitle.isEmpty, !remoteComic.title.isEmpty {
                comicTitle = remoteComic.title
            }
            if !hasConsumedRemoteRatio, let ratio = remoteComic.lastReadPositionRatio {
                remoteInitialPositionRatio = ratio
            }
        }

        if groupContext == nil,
           let resolved = await api.resolveReadingGroupContext(
               for: targetComicId,
               libraryId: remoteComic?.libraryId,
               relativePath: remoteComic?.relativePath ?? remoteComic?.fileLocation?.relativePath
           ),
           !Task.isCancelled,
           targetComicId == currentComicId {
            groupContext = resolved.context
        }

        if let remoteBookmarks {
            bookmarks = remoteBookmarks.sorted {
                if $0.pageIndex != $1.pageIndex {
                    return $0.pageIndex < $1.pageIndex
                }
                return $0.positionRatio < $1.positionRatio
            }
        }

        if let remoteHighlights {
            highlights = remoteHighlights.sorted {
                if $0.chapterIndex != $1.chapterIndex {
                    return $0.chapterIndex < $1.chapterIndex
                }
                return $0.createdAt < $1.createdAt
            }
        }

        if let globalNovel = remotePrefs?.globalNovel, !globalNovel.isEmpty {
            cachedGlobalNovelPrefs = globalNovel
            if let fs = globalNovel["fontSize"]?.doubleValue {
                cloudFontSize = fs.clamped(to: 12...30, default: 17)
            }
            let effectiveFontSize = cloudFontSize ?? 17
            if let ls = globalNovel["lineSpacing"]?.doubleValue {
                cloudLineSpacing = ls.clamped(to: 2...24, default: 10)
            } else if let lh = globalNovel["lineHeight"]?.doubleValue {
                let converted = ((lh - 1.0) * effectiveFontSize).rounded()
                cloudLineSpacing = converted.clamped(to: 2...24, default: 10)
            }
            if let kern = (globalNovel["letterSpacing"] ?? globalNovel["kern"])?.doubleValue {
                cloudLetterSpacing = kern.clamped(to: 0...5, default: 0)
            }
            if let explicitDark = globalNovel["darkMode"]?.boolValue {
                cloudDarkMode = explicitDark
                darkMode = explicitDark
            } else if let theme = globalNovel["theme"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                let isNight = (theme == "night" || theme == "dark")
                cloudDarkMode = isNight
                darkMode = isNight
            }
            cloudPreferenceRevision += 1
        }
    }

    // MARK: - 分页

    func repaginate(
        fontSize: Double,
        lineSpacing: Double? = nil,
        letterSpacing: Double? = nil
    ) async {
        guard let content = chapterContent else { return }
        if let lineSpacing { typographyLineSpacing = lineSpacing }
        if let letterSpacing { typographyLetterSpacing = letterSpacing }

        appendPaginationRequestID = nil
        appendPaginationTask?.cancel()
        appendPaginationTask = nil
        appendedChapterContent = nil

        paginationTask?.cancel()
        let requestID = UUID()
        paginationRequestID = requestID

        let rawContent = content.content ?? ""
        let mimeType = content.mimeType
        let title = content.title
        let chapter = currentChapter
        let size = paginationSize
        let resolvedLineSpacing = typographyLineSpacing
        let resolvedLetterSpacing = typographyLetterSpacing

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let newPages = await self.buildPages(
                rawContent: rawContent,
                mimeType: mimeType,
                title: title,
                comicId: self.comicId,
                fontSize: fontSize,
                lineSpacing: resolvedLineSpacing,
                letterSpacing: resolvedLetterSpacing,
                size: size,
                priority: .userInitiated
            )
            guard !Task.isCancelled,
                  self.paginationRequestID == requestID else {
                return
            }
            self.chapterPageOffsets = [chapter: 0]
            self.nextChapterAppended = false
            self.pages = newPages
            self.lastPaginatedTypography = (fontSize, resolvedLineSpacing, resolvedLetterSpacing)
            self.paginationGeneration += 1
        }
        paginationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func relativePageInChapter(_ absolutePage: Int) -> Int {
        let offset = chapterPageOffsets[currentChapter] ?? 0
        return max(1, absolutePage - offset + 1)
    }

    func currentChapterPageCount() -> Int {
        let offset = chapterPageOffsets[currentChapter] ?? 0
        let nextOffset = chapterPageOffsets[currentChapter + 1] ?? pages.count
        return max(1, nextOffset - offset)
    }

    // MARK: - 无缝翻页

    func tryAppendNextChapter(currentPage: Int, fontSize: Double) {
        guard !nextChapterAppended else { return }
        let chapterEnd = chapterPageOffsets[currentChapter + 1] ?? pages.count
        let pagesRemaining = chapterEnd - currentPage
        guard pagesRemaining <= 2 else { return }

        let nextIndex = currentChapter + 1
        if totalChapters > 0 && nextIndex >= totalChapters { return }

        nextChapterAppended = true
        let requestID = UUID()
        appendPaginationRequestID = requestID
        appendPaginationTask?.cancel()
        appendPaginationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let content: ChapterContent
            if let cached = self.cache.get(nextIndex) {
                content = cached
            } else {
                do {
                    content = try await self.loadChapterContent(
                        comicId: self.comicId,
                        index: nextIndex
                    )
                    self.cache.put(content, for: nextIndex)
                } catch {
                    guard self.appendPaginationRequestID == requestID else { return }
                    AppLogger.error("追加下一章失败: \(error)")
                    self.nextChapterAppended = false
                    return
                }
            }

            let rawContent = content.content ?? ""
            let mimeType = content.mimeType
            let size = self.paginationSize
            let appendPages = await self.buildPages(
                rawContent: rawContent,
                mimeType: mimeType,
                title: content.title,
                comicId: self.comicId,
                fontSize: fontSize,
                lineSpacing: self.typographyLineSpacing,
                letterSpacing: self.typographyLetterSpacing,
                size: size,
                priority: .utility
            )

            guard !Task.isCancelled,
                  self.appendPaginationRequestID == requestID,
                  self.currentChapter == nextIndex - 1 else {
                return
            }
            let startIdx = self.pages.count
            self.chapterPageOffsets[nextIndex] = startIdx
            self.pages.append(contentsOf: appendPages)
            self.appendedChapterContent = content
            self.appendPaginationRequestID = nil
            self.appendPaginationTask = nil
        }
    }

    func advanceToNextChapter(currentPage: Int, fontSize: Double) {
        let nextIndex = currentChapter + 1
        guard let nextOffset = chapterPageOffsets[nextIndex] else { return }
        guard currentPage >= nextOffset else { return }
        guard let content = appendedChapterContent ?? cache.get(nextIndex) else { return }

        chapterContent = content
        appendedChapterContent = nil
        currentChapter = nextIndex
        nextChapterAppended = false
        cache.preloadAdjacent(comicId: comicId, currentChapter: currentChapter, totalChapters: totalChapters)
    }

    private func buildPages(
        rawContent: String,
        mimeType: String?,
        title: String?,
        comicId: String,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        size: CGSize,
        priority: TaskPriority
    ) async -> [NovelPage] {
        let parseTask = Task.detached(priority: priority) {
            NovelContentParser.blocks(content: rawContent, mimeType: mimeType)
        }
        let blocks = await withTaskCancellationHandler {
            await parseTask.value
        } onCancel: {
            parseTask.cancel()
        }
        guard !Task.isCancelled else { return [] }

        let references = Array(Dictionary(
            blocks.compactMap { block -> (String, NovelImageReference)? in
                guard case let .image(reference) = block else { return nil }
                return (reference.source, reference)
            },
            uniquingKeysWith: { first, _ in first }
        ).values)
        var imagesBySource: [String: NovelResolvedImage] = [:]
        if !references.isEmpty {
            let persistOffline = await NovelResourceService.isOfflineNovel(comicId: comicId)
            guard !Task.isCancelled else { return [] }
            let maxConcurrentImages = 4
            await withTaskGroup(of: NovelResolvedImage.self) { group in
                var nextIndex = 0
                let initialCount = min(maxConcurrentImages, references.count)
                while nextIndex < initialCount {
                    let ref = references[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await NovelResourceService.loadImage(
                            reference: ref,
                            comicId: comicId,
                            persistOffline: persistOffline
                        )
                    }
                }
                for await image in group {
                    imagesBySource[image.reference.source] = image
                    if nextIndex < references.count && !Task.isCancelled {
                        let ref = references[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            await NovelResourceService.loadImage(
                                reference: ref,
                                comicId: comicId,
                                persistOffline: persistOffline
                            )
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return [] }

        let resolved = blocks.map { block -> NovelResolvedBlock in
            switch block {
            case let .text(text):
                return .text(text)
            case let .image(reference):
                return .image(imagesBySource[reference.source] ?? NovelResolvedImage(
                    reference: reference,
                    data: nil,
                    pixelWidth: 0,
                    pixelHeight: 0
                ))
            }
        }
        let paginationTask = Task.detached(priority: priority) {
            PaginationService.paginateNovel(
                blocks: resolved,
                title: title,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                maxWidth: size.width,
                maxHeight: size.height
            )
        }
        return await withTaskCancellationHandler {
            await paginationTask.value
        } onCancel: {
            paginationTask.cancel()
        }
    }

    // MARK: - 在线与离线数据源

    private func loadChapterContent(
        comicId: String,
        index: Int
    ) async throws -> ChapterContent {
        let preferOffline = api.isOfflineMode
            || !api.isNetworkReachable
            || DownloadManager.shared.isDownloaded(comicId: comicId)
        if preferOffline {
            let manager = OfflineFileManager.shared
            if let local = await Task.detached(priority: .utility, operation: {
                manager.loadNovelChapter(comicId: comicId, chapter: index)
            }).value {
                return local
            }
        }
        do {
            return try await api.fetchChapter(comicId: comicId, index: index)
        } catch {
            let manager = OfflineFileManager.shared
            if let local = await Task.detached(priority: .utility, operation: {
                manager.loadNovelChapter(comicId: comicId, chapter: index)
            }).value {
                AppLogger.log("网络不可用，从本地缓存加载小说章节")
                return local
            }
            throw error
        }
    }

    private func loadPageList(comicId: String) async -> PageList? {
        let preferOffline = api.isOfflineMode
            || !api.isNetworkReachable
            || DownloadManager.shared.isDownloaded(comicId: comicId)
        if preferOffline, let local = await loadLocalPageList(comicId: comicId) {
            return local
        }
        do {
            let pageList = try await api.fetchPages(comicId: comicId)
            let manager = OfflineFileManager.shared
            await Task.detached(priority: .utility) {
                guard manager.loadMeta(comicId: comicId)?.isNovel == true else {
                    return
                }
                try? manager.saveNovelPageList(pageList, comicId: comicId)
            }.value
            return pageList
        } catch {
            return await loadLocalPageList(comicId: comicId)
        }
    }

    private func loadLocalPageList(comicId: String) async -> PageList? {
        let manager = OfflineFileManager.shared
        return await Task.detached(priority: .utility) {
            if let pageList = manager.loadNovelPageList(comicId: comicId) {
                return pageList
            }
            guard let meta = manager.loadMeta(comicId: comicId),
                  meta.isNovel == true else {
                return nil
            }
            let pages = (0..<meta.pageCount).map {
                PageEntry(
                    index: $0,
                    name: nil,
                    url: nil,
                    title: nil,
                    level: nil,
                    parentIndex: nil,
                    hasChildren: nil
                )
            }
            return PageList(
                comicId: comicId,
                title: meta.title,
                totalPages: meta.pageCount,
                isNovel: true,
                isPdf: false,
                pages: pages
            )
        }.value
    }
}

// MARK: - 书签与笔记抽屉（Phase 2）

private enum NovelNotesDrawerTab: String, CaseIterable, Identifiable {
    case bookmarks = "书签"
    case highlights = "划线批注"
    var id: String { rawValue }
}

private enum NovelHighlightPresetColor: String, CaseIterable, Identifiable {
    case amber = "#fbbf24"
    case emerald = "#34d399"
    case sky = "#60a5fa"
    case pink = "#f472b6"
    case violet = "#a78bfa"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amber: return "琥珀"
        case .emerald: return "翠绿"
        case .sky: return "晴蓝"
        case .pink: return "樱粉"
        case .violet: return "紫罗兰"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .amber: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .emerald: return Color(red: 0.20, green: 0.83, blue: 0.60)
        case .sky: return Color(red: 0.38, green: 0.65, blue: 0.98)
        case .pink: return Color(red: 0.96, green: 0.45, blue: 0.71)
        case .violet: return Color(red: 0.65, green: 0.55, blue: 0.98)
        }
    }

    static func color(for hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first(where: { $0.rawValue == normalized })?.swiftUIColor ?? .yellow
    }
}

struct NovelBookmarksAndNotesSheet: View {
    let comicTitle: String
    let currentChapter: Int
    let currentChapterTitle: String
    let currentPositionRatio: Double
    let currentPagePreview: String
    let bookmarks: [UserBookmark]
    let highlights: [UserHighlight]
    let isBusy: Bool
    let onJumpToLocation: (Int, Double?) -> Void
    let onJumpToHighlight: (UserHighlight) -> Void
    let onUpdateBookmark: (UserBookmark, String, String) async -> Void
    let onDeleteBookmark: (UserBookmark) async -> Void
    let onAddHighlight: (String, String, String) async -> Void
    let onUpdateHighlight: (UserHighlight, String, String) async -> Void
    let onDeleteHighlight: (UserHighlight) async -> Void
    let onExportMarkdown: () async throws -> URL

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: NovelNotesDrawerTab = .bookmarks
    @State private var editingBookmark: UserBookmark?
    @State private var editingHighlight: UserHighlight?
    @State private var isCreatingHighlight = false
    @State private var isExporting = false
    @State private var exportedFileItem: ExportedOriginalFileItem?
    @State private var exportErrorMessage: String?
    @State private var isExportErrorPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $selectedTab) {
                    Text("书签 (\(bookmarks.count))").tag(NovelNotesDrawerTab.bookmarks)
                    Text("划线批注 (\(highlights.count))").tag(NovelNotesDrawerTab.highlights)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                switch selectedTab {
                case .bookmarks:
                    NovelBookmarksListSection(
                        bookmarks: bookmarks,
                        currentChapter: currentChapter,
                        currentPositionRatio: currentPositionRatio,
                        onJumpToLocation: onJumpToLocation,
                        onEditBookmark: { editingBookmark = $0 },
                        onDeleteBookmark: onDeleteBookmark
                    )
                case .highlights:
                    NovelHighlightsListSection(
                        highlights: highlights,
                        onJumpToHighlight: onJumpToHighlight,
                        onEditHighlight: { editingHighlight = $0 },
                        onDeleteHighlight: onDeleteHighlight
                    )
                }
            }
            .navigationTitle("书签与笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isCreatingHighlight = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新增章节批注")
                    .disabled(isBusy)

                    Button {
                        exportMarkdown()
                    } label: {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .accessibilityLabel("导出 Markdown 读书笔记")
                    .disabled(isExporting)
                }
            }
            .sheet(item: $editingBookmark) { bookmark in
                BookmarkEditorSheet(
                    title: "编辑书签（\(bookmark.chapterTitle.isEmpty ? "第 \(bookmark.pageIndex + 1) 章" : bookmark.chapterTitle)）",
                    initialName: bookmark.name,
                    initialNote: bookmark.note
                ) { name, note in
                    await onUpdateBookmark(bookmark, name, note)
                }
            }
            .sheet(isPresented: $isCreatingHighlight) {
                NovelHighlightEditorSheet(
                    title: "添加批注（\(currentChapterTitle)）",
                    initialText: currentPagePreview,
                    initialNote: "",
                    initialColor: NovelHighlightPresetColor.amber.rawValue,
                    allowsTextEditing: true
                ) { text, note, color in
                    await onAddHighlight(text, note, color)
                    selectedTab = .highlights
                }
            }
            .sheet(item: $editingHighlight) { highlight in
                NovelHighlightEditorSheet(
                    title: "编辑批注（\(highlight.chapterTitle.isEmpty ? "第 \(highlight.chapterIndex + 1) 章" : highlight.chapterTitle)）",
                    initialText: highlight.text,
                    initialNote: highlight.note,
                    initialColor: highlight.color,
                    allowsTextEditing: false
                ) { _, note, color in
                    await onUpdateHighlight(highlight, note, color)
                }
            }
            .sheet(item: $exportedFileItem, onDismiss: {
                if let url = exportedFileItem?.url {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                exportedFileItem = nil
            }) { item in
                OriginalFileShareSheet(fileURL: item.url)
            }
            .alert("导出失败", isPresented: $isExportErrorPresented) {
                Button("确定", role: .cancel) { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
        }
    }

    private func exportMarkdown() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let fileURL = try await onExportMarkdown()
                exportedFileItem = ExportedOriginalFileItem(url: fileURL)
            } catch {
                exportErrorMessage = error.localizedDescription
                isExportErrorPresented = true
            }
        }
    }
}

private struct NovelBookmarksListSection: View {
    let bookmarks: [UserBookmark]
    let currentChapter: Int
    let currentPositionRatio: Double
    let onJumpToLocation: (Int, Double?) -> Void
    let onEditBookmark: (UserBookmark) -> Void
    let onDeleteBookmark: (UserBookmark) async -> Void

    var body: some View {
        if bookmarks.isEmpty {
            ContentUnavailableView(
                "暂无书签",
                systemImage: "bookmark",
                description: Text("阅读时点击顶部书签按钮可保存当前章节位置")
            )
        } else {
            List {
                ForEach(bookmarks) { bookmark in
                    NovelBookmarkRow(
                        bookmark: bookmark,
                        isCurrentLocation: bookmark.pageIndex == currentChapter
                            && abs(bookmark.positionRatio - currentPositionRatio) < 0.08,
                        onSelect: {
                            onJumpToLocation(bookmark.pageIndex, bookmark.positionRatio)
                        },
                        onEdit: { onEditBookmark(bookmark) }
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
                            onEditBookmark(bookmark)
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
}

private struct NovelHighlightsListSection: View {
    let highlights: [UserHighlight]
    let onJumpToHighlight: (UserHighlight) -> Void
    let onEditHighlight: (UserHighlight) -> Void
    let onDeleteHighlight: (UserHighlight) async -> Void

    var body: some View {
        if highlights.isEmpty {
            ContentUnavailableView(
                "暂无划线批注",
                systemImage: "highlighter",
                description: Text("点击右上角笔形按钮为当前章节添加摘录或批注")
            )
        } else {
            List {
                ForEach(highlights) { highlight in
                    NovelHighlightRow(
                        highlight: highlight,
                        onSelect: { onJumpToHighlight(highlight) },
                        onEdit: { onEditHighlight(highlight) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await onDeleteHighlight(highlight) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            onEditHighlight(highlight)
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
}

private struct NovelBookmarkRow: View {
    let bookmark: UserBookmark
    let isCurrentLocation: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    private var chapterLabel: String {
        bookmark.chapterTitle.isEmpty ? "第 \(bookmark.pageIndex + 1) 章" : bookmark.chapterTitle
    }

    private var percentLabel: String {
        "\(Int((bookmark.positionRatio * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(chapterLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isCurrentLocation ? Color.orange : Color.accentColor)
                            .lineLimit(1)

                        Text(percentLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

                    Text(bookmark.name.isEmpty ? chapterLabel : bookmark.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !bookmark.note.isEmpty {
                        Text(bookmark.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

private struct NovelHighlightRow: View {
    let highlight: UserHighlight
    let onSelect: () -> Void
    let onEdit: () -> Void

    private var chapterLabel: String {
        highlight.chapterTitle.isEmpty ? "第 \(highlight.chapterIndex + 1) 章" : highlight.chapterTitle
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(NovelHighlightPresetColor.color(for: highlight.color))
                        .frame(width: 4)
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapterLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(highlight.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(4)

                        if !highlight.note.isEmpty {
                            Text(highlight.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .accessibilityLabel("编辑批注")
        }
    }
}

private struct NovelHighlightEditorSheet: View {
    let title: String
    let initialText: String
    let initialNote: String
    let initialColor: String
    let allowsTextEditing: Bool
    let onSave: (String, String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var note: String = ""
    @State private var selectedColor: String = NovelHighlightPresetColor.amber.rawValue
    @State private var isSaving = false

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("摘录内容") {
                    if allowsTextEditing {
                        TextField("输入或粘贴原文片段", text: $text, axis: .vertical)
                            .lineLimit(3...8)
                    } else {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("批注笔记") {
                    TextField("写下你的想法（可选）", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("高亮颜色") {
                    HStack(spacing: 14) {
                        ForEach(NovelHighlightPresetColor.allCases) { preset in
                            Button {
                                selectedColor = preset.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(preset.swiftUIColor)
                                        .frame(width: 30, height: 30)
                                    if selectedColor.lowercased() == preset.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.label)
                        }
                    }
                    .padding(.vertical, 4)
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
                            await onSave(text, note, selectedColor)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                text = initialText
                note = initialNote
                let normalized = initialColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                selectedColor = NovelHighlightPresetColor(rawValue: normalized)?.rawValue
                    ?? NovelHighlightPresetColor.amber.rawValue
            }
        }
    }
}

// MARK: - 小说全书检索面板（Phase 3）

struct NovelSearchSheet: View {
    let comicId: String
    let currentChapter: Int
    let totalChapters: Int
    let onOfflineFallbackSearch: (String, Int) async -> NovelSearchResponse
    let onSelectResult: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFieldFocused: Bool
    @State private var queryText = ""
    @State private var activeQuery = ""
    @State private var searchResponse: NovelSearchResponse?
    @State private var isSearching = false
    @State private var isOfflineFallback = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NovelSearchBarSection(
                    queryText: $queryText,
                    isSearchFieldFocused: $isSearchFieldFocused,
                    isSearching: isSearching,
                    isSearchDisabled: trimmedQuery.isEmpty,
                    onSubmit: triggerImmediateSearch,
                    onClear: clearSearch,
                    onCancelSearch: {
                        searchTask?.cancel()
                        isSearching = false
                    }
                )
                Divider()
                NovelSearchResultsSection(
                    isSearching: isSearching,
                    totalChapters: totalChapters,
                    errorMessage: errorMessage,
                    searchResponse: searchResponse,
                    activeQuery: activeQuery,
                    currentChapter: currentChapter,
                    isOfflineFallback: isOfflineFallback,
                    onRetry: triggerImmediateSearch,
                    onSelectResult: { chapterIndex, query in
                        searchTask?.cancel()
                        onSelectResult(chapterIndex, query)
                    }
                )
            }
            .navigationTitle("全书搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear {
                isSearchFieldFocused = true
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .onChange(of: queryText) { _, newValue in
                scheduleDebouncedSearch(for: newValue)
            }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        queryText = ""
        activeQuery = ""
        searchResponse = nil
        errorMessage = nil
        isSearching = false
        isOfflineFallback = false
    }

    private func scheduleDebouncedSearch(for rawValue: String) {
        searchTask?.cancel()
        let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            activeQuery = ""
            searchResponse = nil
            errorMessage = nil
            isSearching = false
            isOfflineFallback = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func triggerImmediateSearch() {
        searchTask?.cancel()
        let query = trimmedQuery
        guard !query.isEmpty else { return }
        searchTask = Task {
            await performSearch(query: query)
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        isSearching = true
        errorMessage = nil
        isOfflineFallback = false
        activeQuery = query
        defer { isSearching = false }

        let api = APIClient.shared
        if !api.isNetworkReachable || api.isOfflineMode {
            let offlineResp = await onOfflineFallbackSearch(query, 100)
            guard !Task.isCancelled else { return }
            isOfflineFallback = true
            searchResponse = offlineResp
            return
        }

        do {
            let response = try await api.searchNovel(comicId: comicId, query: query, limit: 100)
            guard !Task.isCancelled else { return }
            searchResponse = response
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let offlineResp = await onOfflineFallbackSearch(query, 100)
            guard !Task.isCancelled else { return }
            if !offlineResp.results.isEmpty {
                isOfflineFallback = true
                searchResponse = offlineResp
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NovelSearchBarSection: View {
    @Binding var queryText: String
    var isSearchFieldFocused: FocusState<Bool>.Binding
    let isSearching: Bool
    let isSearchDisabled: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onCancelSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("输入关键词搜索全书章节", text: $queryText)
                    .focused(isSearchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(onSubmit)

                if !queryText.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除关键词")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if isSearching {
                Button("取消", action: onCancelSearch)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
            } else {
                Button("搜索", action: onSubmit)
                    .font(.subheadline.weight(.medium))
                    .disabled(isSearchDisabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

private struct NovelSearchResultsSection: View {
    let isSearching: Bool
    let totalChapters: Int
    let errorMessage: String?
    let searchResponse: NovelSearchResponse?
    let activeQuery: String
    let currentChapter: Int
    let isOfflineFallback: Bool
    let onRetry: () -> Void
    let onSelectResult: (Int, String) -> Void

    var body: some View {
        if isSearching && searchResponse == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text(totalChapters > 0 ? "正在检索全书 \(totalChapters) 个章节..." : "正在检索...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        } else if let resp = searchResponse {
            if resp.results.isEmpty {
                ContentUnavailableView(
                    "未找到匹配内容",
                    systemImage: "magnifyingglass",
                    description: Text("没有找到包含“\(resp.query)”的章节")
                )
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("在 \(resp.matchedChapters) 个章节中找到 \(resp.totalMatches) 处匹配")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isOfflineFallback {
                                    Text("本地缓存")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }

                            if resp.truncated {
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle.fill")
                                        .font(.caption)
                                    Text("匹配结果已截断（仅显示前 \(resp.results.count) 章），建议使用更精确的关键词。")
                                        .font(.caption)
                                }
                                .foregroundStyle(.orange)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(resp.results) { item in
                            NovelSearchResultRow(
                                item: item,
                                keyword: activeQuery,
                                isCurrentChapter: item.chapterIndex == currentChapter,
                                onTap: { onSelectResult(item.chapterIndex, activeQuery) }
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            ContentUnavailableView(
                "搜索全书内容",
                systemImage: "text.magnifyingglass",
                description: Text(
                    totalChapters > 0
                        ? "支持服务端全文检索共 \(totalChapters) 个章节，点击结果将直接定位到对应页面"
                        : "输入关键词后将自动检索全书匹配章节"
                )
            )
        }
    }
}

private struct NovelSearchResultRow: View {
    let item: NovelSearchResultItem
    let keyword: String
    let isCurrentChapter: Bool
    let onTap: () -> Void

    private var chapterDisplayTitle: String {
        let trimmed = item.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "第 \(item.chapterIndex + 1) 章" : trimmed
    }

    private var highlightedSnippet: AttributedString {
        var result = AttributedString(item.matchText)
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }

        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) {
            result[range].backgroundColor = .yellow.opacity(0.35)
            result[range].foregroundColor = .primary
            result[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return result
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(chapterDisplayTitle)
                        .font(.subheadline.weight(isCurrentChapter ? .bold : .semibold))
                        .foregroundStyle(isCurrentChapter ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(item.matchCount) 处")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }

                if !item.matchText.isEmpty {
                    Text(highlightedSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Extensions
