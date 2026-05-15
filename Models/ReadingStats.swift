import Foundation

struct ReadingStats: Codable {
    let totalReadTime: Int        // 秒
    let totalSessions: Int
    let totalComicsRead: Int
    let totalPagesRead: Int?
    let dailyStats: [DailyStat]?
    let recentSessions: [RecentSession]?
}

struct DailyStat: Codable, Identifiable {
    let date: String
    let duration: Int
    let sessions: Int

    var id: String { date }
}

struct RecentSession: Codable, Identifiable {
    let id: Int?
    let comicId: String?
    let comicTitle: String?
    let startPage: Int?
    let endPage: Int?
    let duration: Int?
    let startedAt: String?

    var idValue: String { "\(id ?? 0)-\(startedAt ?? "")" }
}
