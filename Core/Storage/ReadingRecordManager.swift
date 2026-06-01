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

    private init() {}

    func save(comicId: String, chapter: Int, page: Int) {
        var records = loadAll()
        records[comicId] = Record(chapter: chapter, page: page, timestamp: Date())
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: UserDefaultsKey.readingRecords)
        }
    }

    func load(comicId: String) -> Record? {
        loadAll()[comicId]
    }

    func remove(comicId: String) {
        var records = loadAll()
        records.removeValue(forKey: comicId)
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: UserDefaultsKey.readingRecords)
        }
    }

    /// 清除超过 30 天的过期记录
    func cleanup(olderThan days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var records = loadAll()
        records = records.filter { $0.value.timestamp >= cutoff }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: UserDefaultsKey.readingRecords)
        }
    }

    private func loadAll() -> [String: Record] {
        guard let data = defaults.data(forKey: UserDefaultsKey.readingRecords),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return records
    }
}
