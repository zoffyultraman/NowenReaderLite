import Foundation

// MARK: - 基础统计（原有）

struct ReadingStats: Codable {
    let totalReadTime: Int
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

// MARK: - 增强统计

struct EnhancedReadingStats: Codable {
    let totalReadTime: Int
    let totalSessions: Int
    let totalComicsRead: Int
    let currentStreak: Int
    let longestStreak: Int
    let avgPagesPerHour: Double
    let todayReadTime: Int
    let weekReadTime: Int
    let dailyStats: [EnhancedDailyStat]
    let monthlyStats: [MonthlyStat]
    let recentSessions: [EnhancedSession]
    let genreStats: [GenreStat]
}

struct EnhancedDailyStat: Codable, Identifiable {
    let date: String
    let duration: Int
    let sessions: Int
    var id: String { date }
}

struct MonthlyStat: Codable, Identifiable {
    let month: String
    let duration: Int
    let sessions: Int
    let comics: Int
    var id: String { month }
}

struct EnhancedSession: Codable, Identifiable {
    let id: Int?
    let comicId: String?
    let comicTitle: String?
    let startedAt: String?
    let endedAt: String?
    let duration: Int?
    let startPage: Int?
    let endPage: Int?
    var idValue: String { "\(id ?? 0)-\(startedAt ?? "")" }
}

struct GenreStat: Codable, Identifiable {
    let genre: String
    let totalTime: Int
    let comicCount: Int
    var id: String { genre }
}

// MARK: - 阅读目标

struct ReadingGoalProgress: Codable, Identifiable {
    let goal: ReadingGoal
    let currentMins: Int
    let currentBooks: Int
    let progressPct: Int
    let bookProgressPct: Int
    let periodStart: String
    let periodEnd: String
    let achieved: Bool
    var id: String { goal.goalType }
}

struct ReadingGoal: Codable {
    let id: Int
    let goalType: String
    let targetMins: Int
    let targetBooks: Int
    let createdAt: String?
    let updatedAt: String?
}

struct GoalSetRequest: Encodable {
    let goalType: String
    let targetMins: Int
    let targetBooks: Int
}

struct ReadingStatusRequest: Encodable {
    let readingStatus: String
}