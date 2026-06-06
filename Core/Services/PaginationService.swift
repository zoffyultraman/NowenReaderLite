import UIKit

/// 纯文本分页算法，无状态，可在任意线程调用
enum PaginationService {

    /// 将纯文本按屏幕尺寸分页，返回每页的文本字符串
    static func paginate(
        text: String,
        fontSize: Double,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        firstPageMaxH: CGFloat? = nil
    ) -> [String] {
        guard !text.isEmpty else { return [""] }

        let font = UIFont.systemFont(ofSize: fontSize)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = fontSize * 0.6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paraStyle]

        let label = UILabel()
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = maxWidth

        let fpMaxH = firstPageMaxH ?? maxHeight
        label.attributedText = NSAttributedString(string: text, attributes: attrs)
        if label.intrinsicContentSize.height <= fpMaxH { return [text] }

        var result: [String] = []
        var remaining = text
        var isFirstPage = true

        while !remaining.isEmpty {
            let pageMaxH = isFirstPage ? fpMaxH : maxHeight
            let pageText = findPageText(text: remaining, attrs: attrs, maxWidth: maxWidth, maxHeight: pageMaxH, label: label)
            result.append(pageText)
            let end = remaining.index(remaining.startIndex, offsetBy: pageText.count)
            remaining = String(remaining[end...])
            isFirstPage = false
        }

        return result
    }

    /// 从 ChapterContent 分页（不更新任何状态）
    static func paginateContent(
        _ content: ChapterContent,
        fontSize: Double,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> [String] {
        let titleHeight: CGFloat = (content.title != nil) ? fontSize * 2.5 : 0
        let firstPageMaxH = maxHeight - titleHeight
        let text = content.content ?? ""
        return paginate(text: text, fontSize: fontSize, maxWidth: maxWidth, maxHeight: maxHeight, firstPageMaxH: firstPageMaxH)
    }

    // MARK: - Private

    /// 二分查找单页能容纳的最大文本
    private static func findPageText(
        text: String,
        attrs: [NSAttributedString.Key: Any],
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        label: UILabel
    ) -> String {
        var low = 1
        var high = text.count
        var best = 1

        while low <= high {
            let mid = (low + high) / 2
            let end = text.index(text.startIndex, offsetBy: min(mid, text.count))
            label.attributedText = NSAttributedString(string: String(text[text.startIndex..<end]), attributes: attrs)
            if label.intrinsicContentSize.height <= maxHeight {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let end = text.index(text.startIndex, offsetBy: min(best, text.count))
        var pageText = String(text[text.startIndex..<end])

        if best < text.count {
            let searchStart = pageText.index(pageText.endIndex, offsetBy: -min(30, pageText.count))
            if let dot = pageText[searchStart..<pageText.endIndex].lastIndex(where: { "。！？.!?".contains($0) }) {
                pageText = String(pageText[pageText.startIndex...dot])
            }
        }

        return pageText
    }
}
