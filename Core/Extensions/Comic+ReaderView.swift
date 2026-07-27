import SwiftUI

// MARK: - 漫画 → 阅读器路由

extension Comic {
    /// 根据漫画类型自动选择对应的阅读器 View
    @MainActor
    @ViewBuilder
    func readerView(groupContext: ReadingGroupContext? = nil) -> some View {
        if isNovel {
            if filename?.lowercased().hasSuffix(".pdf") == true {
                PDFReaderView(comicId: id, initialPage: lastReadPage)
            } else {
                NovelReaderView(comicId: id, initialChapter: lastReadPage, groupContext: groupContext)
            }
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
