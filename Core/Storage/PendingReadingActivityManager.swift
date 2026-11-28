import Foundation

/// 阅读活动暂存。每个 clientSessionId 只保留最新累计快照，联网后补传给服务端。
final class PendingReadingActivityManager: @unchecked Sendable {
    static let shared = PendingReadingActivityManager()

    struct PendingActivity: Codable, Sendable {
        let comicId: String
        let clientSessionId: String
        var page: Int
        var totalPages: Int
        var positionRatio: Double? = nil
        var activeSeconds: Int
        var sequence: Int
        var finalize: Bool
        var trackProgress: Bool
        var updatedAt: Date
    }

    private let key = "pending_reading_activities"
    private let queue = DispatchQueue(label: "PendingReadingActivityManager")
    private let persistQueue = DispatchQueue(label: "PendingReadingActivityManager.persist", qos: .utility)
    private var cache: [String: PendingActivity] = [:]
    private var persistGeneration: UInt64 = 0

    private init() {
        cache = loadFromDisk()
    }

    func save(
        comicId: String,
        clientSessionId: String,
        page: Int,
        totalPages: Int,
        positionRatio: Double? = nil,
        activeSeconds: Int,
        sequence: Int,
        finalize: Bool,
        trackProgress: Bool
    ) {
        let clampedRatio = positionRatio.map { min(max($0, 0.0), 1.0) }
        save(PendingActivity(
            comicId: comicId,
            clientSessionId: clientSessionId,
            page: page,
            totalPages: totalPages,
            positionRatio: clampedRatio,
            activeSeconds: activeSeconds,
            sequence: sequence,
            finalize: finalize,
            trackProgress: trackProgress,
            updatedAt: Date()
        ))
    }

    func save(_ activity: PendingActivity) {
        guard activity.finalize || activity.activeSeconds > 0 else { return }
        var didSave = false
        queue.sync {
            if let existing = cache[activity.clientSessionId],
               existing.sequence > activity.sequence {
                return
            }

            var next = activity
            next.updatedAt = Date()
            if let existing = cache[activity.clientSessionId],
               existing.sequence == activity.sequence {
                next.activeSeconds = max(existing.activeSeconds, activity.activeSeconds)
                next.finalize = existing.finalize || activity.finalize
            }

            cache[activity.clientSessionId] = next
            persistGeneration &+= 1
            let snapshot = cache
            let generation = persistGeneration
            schedulePersist(snapshot: snapshot, generation: generation)
            didSave = true
        }

        if didSave {
            AppLogger.log("阅读活动已暂存待补传: \(activity.comicId) seq=\(activity.sequence) seconds=\(activity.activeSeconds)")
        }
    }

    func loadAll() -> [PendingActivity] {
        queue.sync {
            cache.values.sorted { $0.updatedAt < $1.updatedAt }
        }
    }

    func removeIfSynced(clientSessionId: String, sequence: Int) {
        queue.sync {
            guard let current = cache[clientSessionId],
                  current.sequence <= sequence else { return }
            cache.removeValue(forKey: clientSessionId)
            persistGeneration &+= 1
            let snapshot = cache
            let generation = persistGeneration
            schedulePersist(snapshot: snapshot, generation: generation)
        }
    }

    var hasPending: Bool {
        queue.sync { !cache.isEmpty }
    }

    private func loadFromDisk() -> [String: PendingActivity] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([String: PendingActivity].self, from: data) else {
            return [:]
        }
        return records.filter { _, activity in activity.finalize || activity.activeSeconds > 0 }
    }

    private func schedulePersist(snapshot: [String: PendingActivity], generation: UInt64) {
        let storageKey = key
        persistQueue.async { [weak self] in
            guard let self else { return }
            let isLatest = self.queue.sync { self.persistGeneration == generation }
            guard isLatest, let data = try? JSONEncoder().encode(snapshot) else { return }
            let stillLatest = self.queue.sync { self.persistGeneration == generation }
            guard stillLatest else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
