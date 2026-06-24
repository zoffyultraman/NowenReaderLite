import Foundation

// MARK: - 基础统计（原有）

struct ReadingStats: Codable {
    let totalReadTime: Int
    let totalSessions: Int
    let totalComicsRead: Int
    let totalPagesRead: Int?
    let dailyStats: [DailyStat]?
    let recentSessions: [RecentSession]?

    // 新版 API 嵌套格式
    struct Summary: Codable {
        let totalComics: Int?
        let totalSessions: Int?
        let totalReadTime: Int?
        let totalPages: Int?
        let avgSessionDuration: Int?
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case totalReadTime, totalSessions, totalComicsRead, totalPagesRead
        case dailyStats, recentSessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 优先尝试嵌套 summary 格式，回退到扁平格式
        if let summary = try container.decodeIfPresent(Summary.self, forKey: .summary) {
            totalReadTime = summary.totalReadTime ?? 0
            totalSessions = summary.totalSessions ?? 0
            totalComicsRead = summary.totalComics ?? 0
            totalPagesRead = summary.totalPages
        } else {
            totalReadTime = try container.decodeIfPresent(Int.self, forKey: .totalReadTime) ?? 0
            totalSessions = try container.decodeIfPresent(Int.self, forKey: .totalSessions) ?? 0
            totalComicsRead = try container.decodeIfPresent(Int.self, forKey: .totalComicsRead) ?? 0
            totalPagesRead = try container.decodeIfPresent(Int.self, forKey: .totalPagesRead)
        }
        dailyStats = try container.decodeIfPresent([DailyStat].self, forKey: .dailyStats)
        recentSessions = try container.decodeIfPresent([RecentSession].self, forKey: .recentSessions)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalReadTime, forKey: .totalReadTime)
        try container.encode(totalSessions, forKey: .totalSessions)
        try container.encode(totalComicsRead, forKey: .totalComicsRead)
        try container.encodeIfPresent(totalPagesRead, forKey: .totalPagesRead)
        try container.encodeIfPresent(dailyStats, forKey: .dailyStats)
        try container.encodeIfPresent(recentSessions, forKey: .recentSessions)
    }
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

    var idValue: String {
        if let id { return "\(id)" }
        return "\(comicId ?? "")-\(startedAt ?? "")-\(UUID().uuidString)"
    }
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
    var idValue: String {
        if let id { return "\(id)" }
        return "\(comicId ?? "")-\(startedAt ?? "")-\(UUID().uuidString)"
    }
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
    let status: String
}

// MARK: - 年度阅读报告

struct YearlyReadingStats: Codable {
    let year: Int
    let monthlyStats: [MonthlyStat]  // 复用已有的 MonthlyStat
    let totalSessions: Int
    let totalReadTime: Int
    let totalBooks: Int
}