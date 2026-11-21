import SwiftUI

// MARK: - 漫画 → 阅读器路由

extension Comic {
    /// 根据文件格式与内容类型自动选择对应的阅读器 View
    @MainActor
    @ViewBuilder
    func readerView(groupContext: ReadingGroupContext? = nil) -> some View {
        if isPdf {
            PDFReaderView(comicId: id, initialPage: lastReadPage)
        } else if isNovel {
            NovelReaderView(comicId: id, initialChapter: lastReadPage, groupContext: groupContext)
        } else {
            ComicReaderView(comicId: id, initialPage: lastReadPage, groupContext: groupContext)
        }
    }
}

extension ComicEditionInfo {
    /// 根据格式版本信息打开对应的阅读器 View
    @MainActor
    @ViewBuilder
    func readerView(isNovelLibrary: Bool, groupContext: ReadingGroupContext? = nil) -> some View {
        if isPdf {
            PDFReaderView(comicId: comicId, initialPage: lastReadPage)
        } else if isNovelLibrary {
            NovelReaderView(comicId: comicId, initialChapter: lastReadPage, groupContext: groupContext)
        } else {
            ComicReaderView(comicId: comicId, initialPage: lastReadPage, groupContext: groupContext)
        }
    }
}

extension GroupComicItem {
    var isPdf: Bool {
        filename?.lowercased().hasSuffix(".pdf") == true
    }

    var isNovel: Bool {
        type?.lowercased() == "novel" && !isPdf
    }

    /// 根据合集分卷信息打开对应的阅读器 View
    @MainActor
    @ViewBuilder
    func readerView(groupContext: ReadingGroupContext? = nil) -> some View {
        if isPdf {
            PDFReaderView(comicId: id, initialPage: lastReadPage)
        } else if isNovel {
            NovelReaderView(comicId: id, initialChapter: lastReadPage, groupContext: groupContext)
        } else {
            ComicReaderView(comicId: id, initialPage: lastReadPage, groupContext: groupContext)
        }
    }
}

extension View {
    @ViewBuilder
    func readerStatusBarHidden(_ hidden: Bool) -> some View {
        if #available(iOS 27.0, *) {
            toolbarVisibility(hidden ? .hidden : .visible, for: .statusBar)
        } else {
            statusBarHidden(hidden)
        }
    }
}
