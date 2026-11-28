import CoreText
import UIKit

/// 纯文本分页算法，无状态，可在任意线程调用
enum PaginationService {

    private static let multiBlankLineRegex = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n(?:[ \t]*\n)+"#
    )
    private static let htmlCommentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#
    )
    private static let htmlIgnorableBlockRegex = try! NSRegularExpression(
        pattern: #"<(script|style|head)\b[^>]*>[\s\S]*?</\1>"#,
        options: [.caseInsensitive]
    )
    private static let htmlLineBreakRegex = try! NSRegularExpression(
        pattern: #"<br\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let htmlSingleBreakTagRegex = try! NSRegularExpression(
        pattern: #"</(?:li|tr)\s*>|<li\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let htmlParagraphBreakTagRegex = try! NSRegularExpression(
        pattern: #"</(?:p|div|h[1-6]|blockquote|section|article|pre|ul|ol|table)\s*>|<(?:p|div|h[1-6]|blockquote|section|article|hr)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let htmlAnyTagRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#
    )

    private static let namedHTMLEntities: [String: String] = [
        "nbsp": " ",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "mdash": "—",
        "ndash": "–",
        "hellip": "…",
        "ldquo": "“",
        "rdquo": "”",
        "lsquo": "‘",
        "rsquo": "’",
        "copy": "©",
        "reg": "®",
        "trade": "™",
        "middot": "·",
        "bull": "•",
        "times": "×",
        "divide": "÷",
    ]

    /// EPUB 章节可能是 HTML；纯文本章节保持原样。纯 Swift 实现，线程安全且不触碰 WebKit。
    static func readableText(content: String, mimeType: String?) -> String {
        guard isHTML(content: content, mimeType: mimeType) else {
            return content
        }

        let mutable = NSMutableString(string: content)
        let fullRange = { NSRange(location: 0, length: mutable.length) }
        htmlCommentRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "")
        htmlIgnorableBlockRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "")
        htmlLineBreakRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "\n")
        htmlSingleBreakTagRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "\n")
        htmlParagraphBreakTagRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "\n\n")
        htmlAnyTagRegex.replaceMatches(in: mutable, range: fullRange(), withTemplate: "")

        let decoded = decodeHTMLEntities(mutable as String)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{fffc}", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")

        let collapsed = NSMutableString(string: decoded)
        multiBlankLineRegex.replaceMatches(
            in: collapsed,
            range: NSRange(location: 0, length: collapsed.length),
            withTemplate: "\n\n"
        )
        return (collapsed as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = String()
        output.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "&",
               let semicolon = text[index...].firstIndex(of: ";"),
               text.distance(from: index, to: semicolon) <= 12 {
                let entityBody = text[text.index(after: index)..<semicolon]
                if let replacement = resolveHTMLEntity(entityBody) {
                    output.append(replacement)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    private static func resolveHTMLEntity(_ entity: Substring) -> String? {
        guard !entity.isEmpty else { return nil }
        if entity.first == "#" {
            let numberPart = entity.dropFirst()
            if numberPart.first == "x" || numberPart.first == "X" {
                if let code = UInt32(numberPart.dropFirst(), radix: 16),
                   let scalar = UnicodeScalar(code) {
                    return String(scalar)
                }
            } else if let code = UInt32(numberPart, radix: 10),
                      let scalar = UnicodeScalar(code) {
                return String(scalar)
            }
            return nil
        }
        return namedHTMLEntities[entity.lowercased()]
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
        paginateWithHeights(
            text: text,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            firstPageMaxH: firstPageMaxH
        ).map(\.text)
    }

    /// 将纯文本按屏幕尺寸分页，同时返回已测量的高度以避免外层二次测高。
    static func paginateWithHeights(
        text: String,
        fontSize: Double,
        lineSpacing: Double = 10,
        letterSpacing: Double = 0,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        firstPageMaxH: CGFloat? = nil
    ) -> [(text: String, height: CGFloat)] {
        guard !text.isEmpty else { return [("", 1)] }
        guard maxWidth > 0, maxHeight > 0 else { return [(text, 1)] }

        let attrs = attributes(
            style: .body,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
        let attributedText = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let source = text as NSString

        var result: [(text: String, height: CGFloat)] = []
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
            let fitted = fittedTextResult(
                in: source,
                location: location,
                candidateLength: min(max(visibleRange.length, 1), remainingLength),
                attributes: attrs,
                maxWidth: maxWidth,
                maxHeight: pageHeight
            )
            var pageLength = fitted.length
            var measuredHeight = fitted.height

            if pageLength < remainingLength {
                let adjustedLength = sentenceBoundaryLength(
                    in: source,
                    location: location,
                    visibleLength: pageLength
                )
                if adjustedLength != pageLength {
                    pageLength = adjustedLength
                    let adjustedFragment = source.substring(
                        with: NSRange(location: location, length: pageLength)
                    )
                    measuredHeight = measuredTextHeight(
                        adjustedFragment,
                        attributes: attrs,
                        maxWidth: maxWidth
                    )
                }
            }

            let pageText = source.substring(with: NSRange(location: location, length: pageLength))
            result.append((pageText, min(measuredHeight, pageHeight)))
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
        return measuredTextHeight(text, attributes: attrs, maxWidth: maxWidth)
    }

    static func measuredTextHeight(
        _ text: String,
        attributes attrs: [NSAttributedString.Key: Any],
        maxWidth: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, maxWidth > 0 else { return 1 }
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
        let attrs = attributes(
            style: style,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
        return fittedTextResult(
            in: source,
            location: location,
            candidateLength: candidateLength,
            attributes: attrs,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        ).length
    }

    static func fittedTextResult(
        in source: NSString,
        location: Int,
        candidateLength: Int,
        attributes attrs: [NSAttributedString.Key: Any],
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> (length: Int, height: CGFloat) {
        guard candidateLength > 0 else { return (0, 1) }
        let safeCandidate = alignedLength(in: source, location: location, length: candidateLength)
        let candidateFragment = source.substring(with: NSRange(location: location, length: safeCandidate))
        let candidateHeight = measuredTextHeight(candidateFragment, attributes: attrs, maxWidth: maxWidth)
        if candidateHeight <= maxHeight {
            return (safeCandidate, candidateHeight)
        }

        // CoreText 与 TextKit 在非零字间距/行间距下偶有微差，二分回退至不裁切为止
        var low = alignedLength(in: source, location: location, length: 1)
        var high = safeCandidate - 1
        var bestLength = low
        var bestHeight = measuredTextHeight(
            source.substring(with: NSRange(location: location, length: low)),
            attributes: attrs,
            maxWidth: maxWidth
        )

        while low <= high {
            if Task.isCancelled { return (bestLength, bestHeight) }
            let rawMid = (low + high) / 2
            var mid = alignedLengthDown(in: source, location: location, length: rawMid)
            if mid < low {
                mid = alignedLength(in: source, location: location, length: rawMid)
            }
            if mid > high {
                // 区间内仅余跨多 UTF-16 单元字符尾部，无法继续对齐；终止避免死循环
                break
            }
            let fragment = source.substring(with: NSRange(location: location, length: mid))
            let height = measuredTextHeight(fragment, attributes: attrs, maxWidth: maxWidth)
            if height <= maxHeight {
                bestLength = mid
                bestHeight = height
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return (bestLength, bestHeight)
    }

    private static func alignedLength(in source: NSString, location: Int, length: Int) -> Int {
        let remaining = source.length - location
        let clamped = min(max(1, length), remaining)
        let endRange = source.rangeOfComposedCharacterSequence(at: location + clamped - 1)
        return min(remaining, endRange.location + endRange.length - location)
    }

    private static func alignedLengthDown(in source: NSString, location: Int, length: Int) -> Int {
        let remaining = source.length - location
        let clamped = min(max(1, length), remaining)
        let endIndex = location + clamped
        let seqRange = source.rangeOfComposedCharacterSequence(at: endIndex - 1)
        let seqEnd = seqRange.location + seqRange.length
        if seqEnd > endIndex {
            if seqRange.location > location {
                return seqRange.location - location
            }
            return min(remaining, seqEnd - location)
        }
        return clamped
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
