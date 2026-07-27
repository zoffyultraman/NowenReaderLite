import CoreText
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
        guard maxWidth > 0, maxHeight > 0 else { return [text] }

        let font = UIFont.systemFont(ofSize: fontSize)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = fontSize * 0.6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paraStyle]
        let attributedText = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let source = text as NSString

        var result: [String] = []
        var location = 0
        var isFirstPage = true

        while location < source.length {
            if Task.isCancelled { return [] }

            let requestedHeight = isFirstPage ? (firstPageMaxH ?? maxHeight) : maxHeight
            let pageHeight = max(1, requestedHeight)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: pageHeight), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            let remainingLength = source.length - location
            var pageLength = min(max(visibleRange.length, 1), remainingLength)

            if pageLength < remainingLength {
                pageLength = sentenceBoundaryLength(
                    in: source,
                    location: location,
                    visibleLength: pageLength
                )
            }

            result.append(source.substring(with: NSRange(location: location, length: pageLength)))
            location += pageLength
            isFirstPage = false
        }

        return result
    }

    // MARK: - Private

    private static func sentenceBoundaryLength(
        in source: NSString,
        location: Int,
        visibleLength: Int
    ) -> Int {
        let tailLength = min(30, visibleLength)
        let tailRange = NSRange(
            location: location + visibleLength - tailLength,
            length: tailLength
        )
        let punctuation = CharacterSet(charactersIn: "。！？.!?")
        let boundary = source.rangeOfCharacter(
            from: punctuation,
            options: .backwards,
            range: tailRange
        )
        if boundary.location != NSNotFound {
            return boundary.location - location + boundary.length
        }
        return visibleLength
    }
}
