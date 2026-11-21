import CoreText
import UIKit

/// 纯文本分页算法，无状态，可在任意线程调用
enum PaginationService {

    /// EPUB 章节可能是 HTML；纯文本章节保持原样。
    static func readableText(content: String, mimeType: String?) -> String {
        guard isHTML(content: content, mimeType: mimeType),
              let data = content.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else {
            return content
        }

        return attributed.string
            .replacingOccurrences(of: "\u{fffc}", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(
                of: #"\n[ \t]*\n(?:[ \t]*\n)+"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将纯文本按屏幕尺寸分页，返回每页的文本字符串
    static func paginate(
        text: String,
        fontSize: Double,
        lineSpacing: Double = 10,
        letterSpacing: Double = 0,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        firstPageMaxH: CGFloat? = nil
    ) -> [String] {
        guard !text.isEmpty else { return [""] }
        guard maxWidth > 0, maxHeight > 0 else { return [text] }

        let attrs = attributes(
            style: .body,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
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
            var pageLength = fittedTextLength(
                in: source,
                location: location,
                candidateLength: min(max(visibleRange.length, 1), remainingLength),
                style: .body,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                maxWidth: maxWidth,
                maxHeight: pageHeight
            )

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

    static func attributes(
        style: NovelTextStyle,
        fontSize: Double,
        lineSpacing: Double = 10,
        letterSpacing: Double = 0,
        textColor: UIColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(max(0, lineSpacing))
        let font: UIFont = style == .title
            ? .boldSystemFont(ofSize: fontSize + 4)
            : .systemFont(ofSize: fontSize)
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .kern: CGFloat(max(0, letterSpacing)),
        ]
        if let textColor {
            result[.foregroundColor] = textColor
        }
        return result
    }

    static func measuredTextHeight(
        _ text: String,
        style: NovelTextStyle,
        fontSize: Double,
        lineSpacing: Double = 10,
        letterSpacing: Double = 0,
        maxWidth: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, maxWidth > 0 else { return 1 }
        let attrs = attributes(
            style: style,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let ctSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let tkRect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return max(1, ceil(max(ctSize.height, tkRect.height)) + 2)
    }

    static func fittedTextLength(
        in source: NSString,
        location: Int,
        candidateLength: Int,
        style: NovelTextStyle,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> Int {
        guard candidateLength > 0 else { return 0 }
        let safeCandidate = alignedLength(in: source, location: location, length: candidateLength)
        let candidateFragment = source.substring(with: NSRange(location: location, length: safeCandidate))
        if measuredTextHeight(
            candidateFragment,
            style: style,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth
        ) <= maxHeight {
            return safeCandidate
        }

        // CoreText 与 TextKit 在非零字间距/行间距下偶有微差，二分回退至不裁切为止
        var low = alignedLength(in: source, location: location, length: 1)
        var high = safeCandidate - 1
        var best = low

        while low <= high {
            if Task.isCancelled { return best }
            let mid = alignedLength(in: source, location: location, length: (low + high) / 2)
            let fragment = source.substring(with: NSRange(location: location, length: mid))
            let height = measuredTextHeight(
                fragment,
                style: style,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                maxWidth: maxWidth
            )
            if height <= maxHeight {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    private static func alignedLength(in source: NSString, location: Int, length: Int) -> Int {
        let remaining = source.length - location
        let clamped = min(max(1, length), remaining)
        let endRange = source.rangeOfComposedCharacterSequence(at: location + clamped - 1)
        return min(remaining, endRange.location + endRange.length - location)
    }

    // MARK: - Private

    static func isHTML(content: String, mimeType: String?) -> Bool {
        if mimeType?.localizedCaseInsensitiveContains("html") == true {
            return true
        }
        let prefix = content.prefix(2048).lowercased()
        return prefix.contains("<html")
            || prefix.contains("<body")
            || prefix.contains("<p")
            || prefix.contains("<div")
            || prefix.contains("<br")
            || prefix.contains("<h1")
    }

    static func sentenceBoundaryLength(
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
