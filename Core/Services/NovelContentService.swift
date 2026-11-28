import CoreText
import ImageIO
import UIKit

struct NovelImageReference: Hashable, Sendable {
    let source: String
    let altText: String?
}

enum NovelContentBlock: Equatable, Sendable {
    case text(String)
    case image(NovelImageReference)
}

struct NovelResolvedImage: Equatable, Sendable {
    let reference: NovelImageReference
    let data: Data?
    let pixelWidth: Double
    let pixelHeight: Double
}

enum NovelResolvedBlock: Equatable, Sendable {
    case text(String)
    case image(NovelResolvedImage)
}

enum NovelTextStyle: Equatable, Sendable {
    case body
    case title
}

struct NovelPageFrame: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct NovelTextPageItem: Equatable, Sendable {
    let text: String
    let style: NovelTextStyle
    let frame: NovelPageFrame
}

struct NovelImagePageItem: Equatable, Sendable {
    let data: Data?
    let altText: String?
    let source: String
    let frame: NovelPageFrame
}

enum NovelPageItem: Equatable, Sendable {
    case text(NovelTextPageItem)
    case image(NovelImagePageItem)
}

struct NovelPage: Equatable, Sendable {
    let items: [NovelPageItem]
}

enum NovelContentParser {
    private static let imageTagExpression = try! NSRegularExpression(
        pattern: #"<(?:img|image)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let sourceExpression = try! NSRegularExpression(
        pattern: #"(?:src|xlink:href|href)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive]
    )
    private static let altExpression = try! NSRegularExpression(
        pattern: #"(?:alt|title)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive]
    )
    private static let multiBlankLineRegex = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n(?:[ \t]*\n)+"#
    )

    static func blocks(content: String, mimeType: String?) -> [NovelContentBlock] {
        guard PaginationService.isHTML(content: content, mimeType: mimeType) else {
            return content.isEmpty ? [] : [.text(content)]
        }

        let source = content as NSString
        let matches = imageTagExpression.matches(
            in: content,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else {
            let text = PaginationService.readableText(content: content, mimeType: mimeType)
            return text.isEmpty ? [] : [.text(text)]
        }

        var replacements: [(range: NSRange, marker: String, reference: NovelImageReference)] = []
        for match in matches {
            let tag = source.substring(with: match.range)
            guard let rawSource = attributeValue(in: tag, using: sourceExpression) else {
                continue
            }
            let decodedSource = decodeHTMLEntities(rawSource)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decodedSource.isEmpty else { continue }
            let alt = attributeValue(in: tag, using: altExpression)
                .map(decodeHTMLEntities)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let marker = "\u{e000}NWR_IMAGE_\(replacements.count)\u{e001}"
            replacements.append((
                range: match.range,
                marker: marker,
                reference: NovelImageReference(source: decodedSource, altText: alt)
            ))
        }

        guard !replacements.isEmpty else {
            let text = PaginationService.readableText(content: content, mimeType: mimeType)
            return text.isEmpty ? [] : [.text(text)]
        }

        let markedHTML = NSMutableString(string: content)
        for replacement in replacements.reversed() {
            markedHTML.replaceCharacters(
                in: replacement.range,
                with: "\n\(replacement.marker)\n"
            )
        }
        let remaining = PaginationService.readableText(
            content: markedHTML as String,
            mimeType: mimeType
        )
        var result: [NovelContentBlock] = []
        var cursor = remaining.startIndex

        for replacement in replacements {
            guard let markerRange = remaining.range(
                of: replacement.marker,
                range: cursor..<remaining.endIndex
            ) else {
                continue
            }
            appendText(remaining[cursor..<markerRange.lowerBound], to: &result)
            result.append(.image(replacement.reference))
            cursor = markerRange.upperBound
        }
        appendText(remaining[cursor..<remaining.endIndex], to: &result)
        return result
    }

    static func imageReferences(content: String, mimeType: String?) -> [NovelImageReference] {
        guard PaginationService.isHTML(content: content, mimeType: mimeType) else {
            return []
        }
        let source = content as NSString
        return imageTagExpression.matches(
            in: content,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            let tag = source.substring(with: match.range)
            guard let rawSource = attributeValue(in: tag, using: sourceExpression) else {
                return nil
            }
            let decodedSource = decodeHTMLEntities(rawSource)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decodedSource.isEmpty else { return nil }
            let alt = attributeValue(in: tag, using: altExpression)
                .map(decodeHTMLEntities)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return NovelImageReference(source: decodedSource, altText: alt)
        }
    }

    private static func appendText<S: StringProtocol>(_ text: S, to result: inout [NovelContentBlock]) {
        let normalized = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        let mutable = NSMutableString(string: normalized)
        multiBlankLineRegex.replaceMatches(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length),
            withTemplate: "\n\n"
        )
        let cleaned = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        result.append(.text(cleaned))
    }

    private static func attributeValue(
        in tag: String,
        using expression: NSRegularExpression
    ) -> String? {
        let source = tag as NSString
        guard let match = expression.firstMatch(
            in: tag,
            range: NSRange(location: 0, length: source.length)
        ) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound {
                return source.substring(with: range)
            }
        }
        return nil
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#38;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#34;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
    }
}

extension PaginationService {
    static func paginateNovel(
        blocks: [NovelResolvedBlock],
        title: String?,
        fontSize: Double,
        lineSpacing: Double = 10,
        letterSpacing: Double = 0,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> [NovelPage] {
        guard maxWidth > 0, maxHeight > 0 else {
            return [NovelPage(items: [])]
        }
        let hasImages = blocks.contains { block in
            if case .image = block { return true }
            return false
        }
        if !hasImages {
            let text = blocks.compactMap { block -> String? in
                guard case let .text(value) = block else { return nil }
                return value
            }.joined(separator: "\n\n")
            return paginatePlainNovel(
                text: text,
                title: title,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                letterSpacing: letterSpacing,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
        }
        return paginateRichNovel(
            blocks: blocks,
            title: title,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
    }

    private static func paginatePlainNovel(
        text: String,
        title: String?,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> [NovelPage] {
        let titleLayout = titleLayout(
            title: title,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth
        )
        let textPages = paginateWithHeights(
            text: text,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            firstPageMaxH: max(1, maxHeight - titleLayout.bodyOffset)
        )

        return textPages.enumerated().map { index, pageEntry in
            var items: [NovelPageItem] = []
            var bodyY: CGFloat = 0
            if index == 0, let titleItem = titleLayout.item {
                items.append(.text(titleItem))
                bodyY = titleLayout.bodyOffset
            }
            items.append(.text(NovelTextPageItem(
                text: pageEntry.text,
                style: .body,
                frame: NovelPageFrame(
                    x: 0,
                    y: bodyY,
                    width: maxWidth,
                    height: min(pageEntry.height, max(1, maxHeight - bodyY))
                )
            )))
            return NovelPage(items: items)
        }
    }

    private static func paginateRichNovel(
        blocks: [NovelResolvedBlock],
        title: String?,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> [NovelPage] {
        let blockSpacing = max(10, CGFloat(fontSize) * 0.7)
        let minimumLineHeight = max(20, CGFloat(fontSize + lineSpacing) * 1.2)
        let bodyAttrs = attributes(
            style: .body,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing
        )
        let titleLayout = titleLayout(
            title: title,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth
        )

        var pages: [NovelPage] = []
        var items: [NovelPageItem] = []
        var cursorY: CGFloat = 0
        if let titleItem = titleLayout.item {
            items.append(.text(titleItem))
            cursorY = titleItem.frame.cgRect.maxY
        }

        func finishPage() {
            guard !items.isEmpty else { return }
            pages.append(NovelPage(items: items))
            items = []
            cursorY = 0
        }

        for block in blocks {
            if Task.isCancelled { return [] }
            switch block {
            case let .text(text):
                let source = text as NSString
                let attributed = NSAttributedString(string: text, attributes: bodyAttrs)
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                var location = 0
                while location < source.length {
                    if Task.isCancelled { return [] }
                    let spacing = items.isEmpty ? 0 : blockSpacing
                    var availableHeight = maxHeight - cursorY - spacing
                    if availableHeight < minimumLineHeight, !items.isEmpty {
                        finishPage()
                        availableHeight = maxHeight
                    }

                    let visible = visibleTextResult(
                        in: source,
                        location: location,
                        framesetter: framesetter,
                        attributes: bodyAttrs,
                        maxWidth: maxWidth,
                        maxHeight: max(1, availableHeight)
                    )
                    guard visible.length > 0 else {
                        if items.isEmpty {
                            let fallback = min(1, source.length - location)
                            let fragment = source.substring(with: NSRange(
                                location: location,
                                length: fallback
                            ))
                            let height = measuredTextHeight(
                                fragment,
                                attributes: bodyAttrs,
                                maxWidth: maxWidth
                            )
                            items.append(.text(NovelTextPageItem(
                                text: fragment,
                                style: .body,
                                frame: NovelPageFrame(
                                    x: 0,
                                    y: cursorY,
                                    width: maxWidth,
                                    height: min(height, maxHeight)
                                )
                            )))
                            location += fallback
                            finishPage()
                        } else {
                            finishPage()
                        }
                        continue
                    }

                    let fragment = source.substring(with: NSRange(
                        location: location,
                        length: visible.length
                    ))
                    let height = min(visible.height, availableHeight)
                    let itemY = cursorY + spacing
                    items.append(.text(NovelTextPageItem(
                        text: fragment,
                        style: .body,
                        frame: NovelPageFrame(
                            x: 0,
                            y: itemY,
                            width: maxWidth,
                            height: height
                        )
                    )))
                    cursorY = itemY + height
                    location += visible.length
                    if location < source.length {
                        finishPage()
                    }
                }

            case let .image(image):
                let spacing = items.isEmpty ? 0 : blockSpacing
                let imageSize = displaySize(
                    for: image,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight * 0.72
                )
                if !items.isEmpty,
                   cursorY + spacing + imageSize.height > maxHeight {
                    finishPage()
                }
                let itemSpacing = items.isEmpty ? 0 : blockSpacing
                let itemY = cursorY + itemSpacing
                let frame = NovelPageFrame(
                    x: max(0, (maxWidth - imageSize.width) / 2),
                    y: itemY,
                    width: imageSize.width,
                    height: min(imageSize.height, maxHeight - itemY)
                )
                items.append(.image(NovelImagePageItem(
                    data: image.data,
                    altText: image.reference.altText,
                    source: image.reference.source,
                    frame: frame
                )))
                cursorY = itemY + frame.height
            }
        }

        finishPage()
        return pages.isEmpty ? [NovelPage(items: [])] : pages
    }

    private static func titleLayout(
        title: String?,
        fontSize: Double,
        lineSpacing: Double,
        letterSpacing: Double,
        maxWidth: CGFloat
    ) -> (item: NovelTextPageItem?, bodyOffset: CGFloat) {
        guard let title, !title.isEmpty else { return (nil, 0) }
        let height = measuredTextHeight(
            title,
            style: .title,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            letterSpacing: letterSpacing,
            maxWidth: maxWidth
        )
        let spacing = max(12, CGFloat(fontSize) * 1.15)
        return (
            NovelTextPageItem(
                text: title,
                style: .title,
                frame: NovelPageFrame(
                    x: 0,
                    y: 0,
                    width: maxWidth,
                    height: height
                )
            ),
            height + spacing
        )
    }

    private static func visibleTextResult(
        in source: NSString,
        location: Int,
        framesetter: CTFramesetter,
        attributes attrs: [NSAttributedString.Key: Any],
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> (length: Int, height: CGFloat) {
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: location, length: 0),
            path,
            nil
        )
        let visible = CTFrameGetVisibleStringRange(frame).length
        guard visible > 0 else { return (0, 1) }
        let remainingLength = source.length - location
        let fitted = fittedTextResult(
            in: source,
            location: location,
            candidateLength: min(visible, remainingLength),
            attributes: attrs,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
        guard fitted.length < remainingLength else { return fitted }
        let adjustedLength = sentenceBoundaryLength(
            in: source,
            location: location,
            visibleLength: fitted.length
        )
        guard adjustedLength != fitted.length else { return fitted }
        let adjustedFragment = source.substring(
            with: NSRange(location: location, length: adjustedLength)
        )
        let adjustedHeight = measuredTextHeight(
            adjustedFragment,
            attributes: attrs,
            maxWidth: maxWidth
        )
        return (adjustedLength, adjustedHeight)
    }

    private static func displaySize(
        for image: NovelResolvedImage,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        guard image.data != nil, image.pixelWidth > 0, image.pixelHeight > 0 else {
            return CGSize(width: maxWidth, height: min(104, maxHeight))
        }
        let sourceWidth = CGFloat(image.pixelWidth)
        let sourceHeight = CGFloat(image.pixelHeight)
        let scale = min(1, maxWidth / sourceWidth, maxHeight / sourceHeight)
        return CGSize(
            width: max(44, sourceWidth * scale),
            height: max(44, sourceHeight * scale)
        )
    }
}

enum NovelResourceService {
    static func loadImage(
        reference: NovelImageReference,
        comicId: String,
        persistOffline: Bool? = nil
    ) async -> NovelResolvedImage {
        do {
            let resolvedPersistOffline: Bool
            if let persistOffline {
                resolvedPersistOffline = persistOffline
            } else {
                resolvedPersistOffline = await isOfflineNovel(comicId: comicId)
            }
            let data = try await resourceData(
                reference: reference,
                comicId: comicId,
                persistOffline: resolvedPersistOffline,
                generation: nil
            )
            let dimensions = imageDimensionsSync(data)
            return NovelResolvedImage(
                reference: reference,
                data: dimensions == nil ? nil : data,
                pixelWidth: dimensions?.width ?? 0,
                pixelHeight: dimensions?.height ?? 0
            )
        } catch {
            AppLogger.log("小说插图加载失败: \(reference.source)")
            return NovelResolvedImage(
                reference: reference,
                data: nil,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }
    }

    static func cacheOfflineResources(
        comicId: String,
        totalChapters: Int,
        generation: String
    ) async -> Bool {
        let manager = OfflineFileManager.shared
        let scanTask = Task.detached(priority: .utility) {
            var unique: [String: NovelImageReference] = [:]
            for chapter in 0..<totalChapters {
                guard !Task.isCancelled,
                      let content = manager.loadNovelChapter(
                        comicId: comicId,
                        chapter: chapter
                      ) else {
                    continue
                }
                for reference in NovelContentParser.imageReferences(
                    content: content.content ?? "",
                    mimeType: content.mimeType
                ) {
                    unique[reference.source] = reference
                }
            }
            return Array(unique.values)
        }
        let references = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        guard !Task.isCancelled else { return false }
        guard !references.isEmpty else { return true }

        let batchSize = 4
        for start in stride(from: 0, to: references.count, by: batchSize) {
            let end = min(start + batchSize, references.count)
            let batch = Array(references[start..<end])
            let succeeded = await withTaskGroup(of: Bool.self) { group in
                for reference in batch {
                    group.addTask {
                        do {
                            _ = try await resourceData(
                                reference: reference,
                                comicId: comicId,
                                persistOffline: true,
                                generation: generation
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var result = true
                for await success in group {
                    result = result && success
                }
                return result
            }
            if !succeeded || Task.isCancelled { return false }
        }
        return true
    }

    static func isOfflineNovel(comicId: String) async -> Bool {
        let manager = OfflineFileManager.shared
        return await Task.detached(priority: .utility) {
            manager.loadMeta(comicId: comicId)?.isNovel == true
        }.value
    }

    private static func resourceData(
        reference: NovelImageReference,
        comicId: String,
        persistOffline: Bool,
        generation: String?
    ) async throws -> Data {
        let manager = OfflineFileManager.shared
        if let local = await Task.detached(priority: .utility, operation: {
            manager.loadNovelResourceData(
                comicId: comicId,
                source: reference.source
            )
        }).value {
            return local
        }

        let primaryServerURL = await MainActor.run { APIClient.shared.primaryServerURL }
        let key = "novel-resource:\(primaryServerURL):\(comicId):\(reference.source)"
        if let cached = await ImageCache.shared.data(forKey: key) {
            if persistOffline {
                try await persist(
                    cached,
                    comicId: comicId,
                    source: reference.source,
                    generation: generation
                )
            }
            return cached
        }

        let data: Data
        if let inline = inlineImageData(from: reference.source) {
            data = inline
        } else {
            guard let url = await MainActor.run(body: {
                APIClient.shared.serverResourceURL(from: reference.source)
            }) else {
                throw APIError.invalidURL
            }
            data = try await APIClient.shared.authenticatedData(
                from: url,
                timeout: 30
            )
        }
        guard !data.isEmpty else { throw APIError.dataFormat }
        ImageCache.shared.setData(data, forKey: key)
        if persistOffline {
            try await persist(
                data,
                comicId: comicId,
                source: reference.source,
                generation: generation
            )
        }
        return data
    }

    private static func persist(
        _ data: Data,
        comicId: String,
        source: String,
        generation: String?
    ) async throws {
        let manager = OfflineFileManager.shared
        try await Task.detached(priority: .utility) {
            try manager.saveNovelResourceData(
                data,
                comicId: comicId,
                source: source,
                generation: generation
            )
        }.value
    }

    private static func imageDimensionsSync(_ data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0,
              height.doubleValue > 0 else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        if let orientation, (5...8).contains(orientation) {
            return (height.doubleValue, width.doubleValue)
        }
        return (width.doubleValue, height.doubleValue)
    }

    private static func inlineImageData(from source: String) -> Data? {
        guard let separator = source.firstIndex(of: ",") else {
            return nil
        }
        let header = source[..<separator].lowercased()
        guard header.hasPrefix("data:image/") else {
            return nil
        }
        let payload = String(source[source.index(after: separator)...])
        if header.contains(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }
}
