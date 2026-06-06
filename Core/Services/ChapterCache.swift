import Foundation

/// 章节缓存管理：存储、淘汰、预加载、标题提取
@MainActor
final class ChapterCache {
    private var cache: [Int: ChapterContent] = [:]
    private var cacheBytes: Int = 0
    private let capacity: Int

    /// 缓存字节数（供设置页读取）
    static var totalNovelCacheBytes: Int = 0

    /// 章节标题索引
    private(set) var chapterTitles: [Int: String] = [:]

    private let api = APIClient.shared

    init(capacity: Int = 5) {
        self.capacity = capacity
    }

    // MARK: - CRUD

    func get(_ index: Int) -> ChapterContent? {
        cache[index]
    }

    func put(_ content: ChapterContent, for index: Int) {
        if let old = cache[index] {
            cacheBytes -= byteSize(old)
        }
        cache[index] = content
        cacheBytes += byteSize(content)
        Self.totalNovelCacheBytes = cacheBytes
        if let title = content.title, !title.isEmpty {
            chapterTitles[index] = title
        }
    }

    func contains(_ index: Int) -> Bool {
        cache[index] != nil
    }

    // MARK: - 淘汰

    /// 淘汰距离当前章节最远的缓存，保留最多 capacity 条
    func evict(keeping center: Int) {
        guard cache.count > capacity else { return }
        let sorted = cache.keys.sorted { abs($0 - center) < abs($1 - center) }
        for key in sorted.dropFirst(capacity) {
            if let removed = cache.removeValue(forKey: key) {
                cacheBytes -= byteSize(removed)
            }
        }
        Self.totalNovelCacheBytes = cacheBytes
    }

    func clear() {
        cache.removeAll()
        cacheBytes = 0
        Self.totalNovelCacheBytes = 0
    }

    // MARK: - 预加载

    /// 预加载当前章节 ±2 的相邻章节（静默失败）
    func preloadAdjacent(comicId: String, currentChapter: Int, totalChapters: Int) {
        for offset in [-2, -1, 1, 2] {
            let target = currentChapter + offset
            guard target >= 0 else { continue }
            if totalChapters > 0 && target >= totalChapters { continue }
            guard cache[target] == nil else { continue }

            Task {
                do {
                    let content = try await api.fetchChapter(comicId: comicId, index: target)
                    put(content, for: target)
                    evict(keeping: currentChapter)
                } catch {
                    // 静默失败
                }
            }
        }
    }

    /// 从 PageList 提取章节标题
    func extractTitles(from pageList: PageList) {
        guard let pages = pageList.pages else { return }
        for entry in pages {
            if let title = entry.title, !title.isEmpty {
                chapterTitles[entry.index] = title
            }
        }
    }

    // MARK: - Private

    private func byteSize(_ content: ChapterContent) -> Int {
        var size = 0
        if let title = content.title { size += title.utf8.count }
        if let text = content.content { size += text.utf8.count }
        return size
    }
}
