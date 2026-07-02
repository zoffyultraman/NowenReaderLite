import Foundation

/// 离线阅读进度暂存，联网后自动同步到服务端
final class PendingProgressManager {
    static let shared = PendingProgressManager()

    struct PendingRecord: Codable {
        var page: Int
        var totalPages: Int?
        var updatedAt: Date
    }

    private let key = "pending_progress"
    private let queue = DispatchQueue(label: "PendingProgressManager", attributes: .concurrent)
    private var _cache: [String: PendingRecord] = [:]

    private init() {
        _cache = loadFromDisk()
    }

    // MARK: - Public

    func save(comicId: String, page: Int, totalPages: Int? = nil) {
        queue.async(flags: .barrier) {
            self._cache[comicId] = PendingRecord(page: page, totalPages: totalPages, updatedAt: Date())
            self.persist()
        }
        AppLogger.log("离线进度已暂存: \(comicId) page=\(page)")
    }

    func loadAll() -> [String: PendingRecord] {
        queue.sync { _cache }
    }

    func remove(comicId: String) {
        queue.async(flags: .barrier) {
            self._cache.removeValue(forKey: comicId)
            self.persist()
        }
    }

    var hasPending: Bool {
        queue.sync { !_cache.isEmpty }
    }

    // MARK: - Private

    private func loadFromDisk() -> [String: PendingRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([String: PendingRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    /// 调用前需确保在 queue 的 barrier 写上下文中
    private func persist() {
        if let data = try? JSONEncoder().encode(_cache) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
