import Foundation

// MARK: - UserDefaults Key 常量

enum UserDefaultsKey {
    static let serverURL = "server_url"
    static let backupServerURL = "backup_server_url"
    static let serverRouteMode = "server_route_mode"
    static let serverRouteIdentities = "server_route_identities"
    static let novelFontSize = "novel_font_size"
    static let novelLineSpacing = "novel_line_spacing"
    static let novelLetterSpacing = "novel_letter_spacing"
    static let readingRecords = "reading_records"

    static func activeServerRoute(for primaryURL: String) -> String {
        "active_server_route_\(primaryURL)"
    }

    static func cookiePreferredRoutes(for primaryURL: String) -> String {
        "cookie_preferred_routes_\(primaryURL)"
    }
}

// MARK: - 阅读记录管理器

@MainActor
final class ReadingRecordManager {
    static let shared = ReadingRecordManager()
    private let defaults = UserDefaults.standard

    struct Record: Codable, Sendable {
        let chapter: Int
        let page: Int
        let totalPages: Int?
        let positionRatio: Double?
        let timestamp: Date

        init(
            chapter: Int,
            page: Int,
            totalPages: Int? = nil,
            positionRatio: Double? = nil,
            timestamp: Date = Date()
        ) {
            self.chapter = chapter
            self.page = page
            self.totalPages = totalPages
            self.positionRatio = positionRatio.map { min(max($0, 0.0), 1.0) }
            self.timestamp = timestamp
        }
    }

    // 内存缓存，避免每次读写都做 JSON 编解码
    private var cache: [String: Record]?
    // 节流写入
    private var flushTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let flushDelay: UInt64 = 1_000_000_000 // 1 秒

    private init() {}

    func save(
        comicId: String,
        chapter: Int,
        page: Int,
        totalPages: Int? = nil,
        positionRatio: Double? = nil
    ) {
        ensureCacheLoaded()
        cache?[comicId] = Record(
            chapter: chapter,
            page: page,
            totalPages: totalPages,
            positionRatio: positionRatio,
            timestamp: Date()
        )
        scheduleFlush()
    }

    func load(comicId: String) -> Record? {
        ensureCacheLoaded()
        return cache?[comicId]
    }

    func remove(comicId: String) {
        ensureCacheLoaded()
        guard cache?.removeValue(forKey: comicId) != nil else { return }
        scheduleFlush()
    }

    /// 清除超过 30 天的过期记录
    func cleanup(olderThan days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        ensureCacheLoaded()
        guard let current = cache else { return }
        let filtered = current.filter { $0.value.timestamp >= cutoff }
        guard filtered.count != current.count else { return }
        cache = filtered
        flush()
    }

    // MARK: - Private

    private func ensureCacheLoaded() {
        if cache != nil { return }
        guard let data = defaults.data(forKey: UserDefaultsKey.readingRecords),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            cache = [:]
            return
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let filtered = records.filter { $0.value.timestamp >= cutoff }
        cache = filtered
        if filtered.count != records.count {
            scheduleFlush()
        }
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

    /// 立即在后台序列化并写入磁盘
    private func flush() {
        guard let snapshot = cache else { return }
        writeTask?.cancel()
        writeTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let data = try? JSONEncoder().encode(snapshot),
                  !Task.isCancelled else {
                return
            }
            UserDefaults.standard.set(data, forKey: UserDefaultsKey.readingRecords)
        }
    }
}
