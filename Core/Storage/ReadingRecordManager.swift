import Foundation

// MARK: - UserDefaults Key 常量

enum UserDefaultsKey {
    static let serverURL = "server_url"
    static let novelFontSize = "novel_font_size"
    static let readingRecords = "reading_records"
}

// MARK: - 阅读记录管理器

@MainActor
final class ReadingRecordManager {
    static let shared = ReadingRecordManager()
    private let defaults = UserDefaults.standard

    struct Record: Codable {
        let chapter: Int
        let page: Int
        let timestamp: Date
    }

    // 内存缓存，避免每次读写都做 JSON 编解码
    private var cache: [String: Record]?
    // 节流写入
    private var flushTask: Task<Void, Never>?
    private let flushDelay: UInt64 = 1_000_000_000 // 1 秒

    private init() {}

    func save(comicId: String, chapter: Int, page: Int) {
        var records = loadAll()
        records[comicId] = Record(chapter: chapter, page: page, timestamp: Date())
        cache = records
        scheduleFlush()
    }

    func load(comicId: String) -> Record? {
        loadAll()[comicId]
    }

    func remove(comicId: String) {
        var records = loadAll()
        records.removeValue(forKey: comicId)
        cache = records
        scheduleFlush()
    }

    /// 清除超过 30 天的过期记录
    func cleanup(olderThan days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var records = loadAll()
        records = records.filter { $0.value.timestamp >= cutoff }
        cache = records
        flush()
    }

    // MARK: - Private

    private func loadAll() -> [String: Record] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: UserDefaultsKey.readingRecords),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        cache = records
        return records
    }

    /// 节流：1 秒内的多次 save 只触发一次磁盘写入
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(nanoseconds: flushDelay)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// 立即写入磁盘
    private func flush() {
        guard let cache else { return }
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: UserDefaultsKey.readingRecords)
        }
    }
}
