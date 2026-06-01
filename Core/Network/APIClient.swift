import Foundation
import SwiftUI
import SwiftData

// MARK: - 统一网络层

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    @Published var serverURL: String = UserDefaults.standard.string(forKey: UserDefaultsKey.serverURL) ?? ""
    @Published var isLoggedIn: Bool = false
    @Published var currentUser: AuthUser?

    private var session: URLSession
    private let cookieStorage = HTTPCookieStorage.shared

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        if !serverURL.isEmpty {
            Task { await checkAuth() }
        }
    }

    // MARK: - Server

    func setServerURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Validate URL scheme — only allow http/https
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              parsed.host != nil, !parsed.host!.isEmpty else {
            return
        }

        // Reject URLs with embedded credentials (user:pass@host)
        if parsed.user != nil { return }

        serverURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: UserDefaultsKey.serverURL)
    }

    func testConnection(_ url: String) async -> Bool {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Auth

    func checkAuth() async {
        guard !serverURL.isEmpty else { return }
        do {
            let resp: AuthMeResponse = try await get("/api/auth/me")
            if let user = resp.user {
                currentUser = user
                isLoggedIn = true
            } else {
                isLoggedIn = false
                currentUser = nil
            }
        } catch {
            isLoggedIn = false
            currentUser = nil
        }
    }

    func login(username: String, password: String) async throws -> AuthUser {
        let body = LoginRequest(username: username, password: password)
        let resp: AuthLoginResponse = try await post("/api/auth/login", body: body)
        currentUser = resp.user
        isLoggedIn = true
        return resp.user
    }

    func register(username: String, password: String, nickname: String) async throws -> AuthUser {
        let body = RegisterRequest(username: username, password: password, nickname: nickname)
        let resp: AuthLoginResponse = try await post("/api/auth/register", body: body)
        currentUser = resp.user
        isLoggedIn = true
        return resp.user
    }

    func logout() async {
        do {
            let _: EmptyResponse = try await post("/api/auth/logout", body: EmptyBody())
        } catch {}
        isLoggedIn = false
        currentUser = nil
        clearCookiesForCurrentServer()
    }

    /// 只清除当前服务器域名的 Cookie，不影响其他服务
    func clearCookiesForCurrentServer() {
        guard let host = URL(string: serverURL)?.host else { return }
        cookieStorage.cookies?.forEach { cookie in
            if cookie.domain == host || cookie.domain.hasSuffix(".\(host)") {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Account Management

    /// 新建账号（保存到 SwiftData + Keychain）
    func createAccount(alias: String, username: String, password: String, context: ModelContext) -> SavedAccount {
        let account = SavedAccount(alias: alias, username: username)
        if !KeychainHelper.savePassword(password, for: account.id) {
            AppLogger.error("Keychain 保存密码失败: \(account.username)")
        }
        context.insert(account)
        context.saveOrLog()
        return account
    }

    /// 更新账号信息
    func updateAccount(_ account: SavedAccount, alias: String, username: String, password: String?, context: ModelContext) {
        account.alias = alias
        account.username = username
        if let password = password {
            if !KeychainHelper.savePassword(password, for: account.id) {
                AppLogger.error("Keychain 更新密码失败: \(account.username)")
            }
        }
        context.saveOrLog()
    }

    /// 删除账号
    func deleteAccount(_ account: SavedAccount, context: ModelContext) {
        if !KeychainHelper.deletePassword(for: account.id) {
            AppLogger.error("Keychain 删除密码失败: \(account.username)")
        }
        // 解绑引用此账号的服务器（@Relationship 会自动处理，但显式清理更安全）
        let allServers = (try? context.fetch(FetchDescriptor<ServerRecord>())) ?? []
        for server in allServers where server.boundAccount?.id == account.id {
            server.boundAccount = nil
        }
        context.delete(account)
        context.saveOrLog()
    }

    /// 获取所有已保存账号
    func fetchAllAccounts(context: ModelContext) -> [SavedAccount] {
        (try? context.fetch(FetchDescriptor<SavedAccount>())) ?? []
    }

    /// 快速登录：用指定账号的凭据登录当前服务器
    func quickLogin(account: SavedAccount) async throws -> AuthUser {
        guard var password = KeychainHelper.readPassword(for: account.id) else {
            throw APIError.networkError
        }
        defer { password = "" }
        let user = try await login(username: account.username, password: password)
        account.lastUsed = Date()
        return user
    }

    // MARK: - Comics

    func fetchComics(
        page: Int = 1,
        pageSize: Int = 20,
        sortBy: String = "addedAt",
        sortOrder: String = "desc",
        search: String? = nil,
        contentType: String? = nil,
        favorites: Bool? = nil,
        readingStatus: String? = nil,
        tag: String? = nil,
        category: String? = nil
    ) async throws -> ComicListResponse {
        var params: [String: String] = [
            "page": "\(page)",
            "pageSize": "\(pageSize)",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
        ]
        if let s = search, !s.isEmpty { params["search"] = s }
        if let t = contentType { params["contentType"] = t }
        if favorites == true { params["favorites"] = "true" }
        if let s = readingStatus { params["readingStatus"] = s }
        if let t = tag { params["tags"] = t }
        if let c = category { params["category"] = c }
        return try await get("/api/comics", query: params)
    }

    func fetchComic(id: String) async throws -> Comic {
        try await get("/api/comics/\(id)")
    }

    func toggleFavorite(comicId: String) async throws -> [String: Bool] {
        try await put("/api/comics/\(comicId)/favorite", body: EmptyBody())
    }

    func updateRating(comicId: String, rating: Int?) async throws {
        let body = RatingBody(rating: rating)
        let _: EmptyResponse = try await put("/api/comics/\(comicId)/rating", body: body)
    }

    func updateProgress(comicId: String, page: Int) async throws {
        let _: EmptyResponse = try await put("/api/comics/\(comicId)/progress", body: PageBody(page: page))
    }

    // MARK: - Pages & Content

    func fetchPages(comicId: String) async throws -> PageList {
        try await get("/api/comics/\(comicId)/pages")
    }

    func fetchChapter(comicId: String, index: Int) async throws -> ChapterContent {
        try await get("/api/comics/\(comicId)/chapter/\(index)")
    }

    func thumbnailURL(comicId: String) -> URL? {
        URL(string: "\(serverURL)/api/comics/\(comicId)/thumbnail")
    }

    func pageImageURL(comicId: String, page: Int) -> URL? {
        URL(string: "\(serverURL)/api/comics/\(comicId)/page/\(page)")
    }

    func pdfURL(comicId: String) -> URL? {
        URL(string: "\(serverURL)/api/comics/\(comicId)/pdf")
    }

    /// 创建带 Cookie 认证的 URLRequest，统一图片/PDF 加载的认证逻辑
    func authenticatedRequest(url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let cookies = cookieStorage.cookies(for: url) {
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        }
        return request
    }

    // MARK: - Sessions

    func startSession(comicId: String, startPage: Int) async throws -> Int? {
        let body = SessionStartBody(comicId: comicId, startPage: startPage)
        let resp: [String: Int] = try await post("/api/stats/session", body: body)
        return resp["sessionId"]
    }

    func endSession(sessionId: Int, endPage: Int, duration: Int) async throws {
        let body = SessionEndBody(sessionId: sessionId, endPage: endPage, duration: duration)
        let _: EmptyResponse = try await put("/api/stats/session", body: body)
    }

    // MARK: - Stats

    func fetchStats() async throws -> ReadingStats {
        try await get("/api/stats")
    }

    func fetchEnhancedStats() async throws -> EnhancedReadingStats {
        try await get("/api/stats/enhanced")
    }

    // MARK: - Goals

    func fetchGoals() async throws -> [ReadingGoalProgress] {
        try await get("/api/goals")
    }

    func setGoal(goalType: String, targetMins: Int, targetBooks: Int) async throws -> ReadingGoal {
        let body = GoalSetRequest(goalType: goalType, targetMins: targetMins, targetBooks: targetBooks)
        return try await post("/api/goals", body: body)
    }

    func deleteGoal(goalType: String) async throws {
        guard var components = URLComponents(string: "\(serverURL)/api/goals") else {
            throw APIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "goalType", value: goalType)]
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Reading Status

    func updateReadingStatus(comicId: String, status: String) async throws {
        let body = ReadingStatusRequest(readingStatus: status)
        let _: EmptyResponse = try await put("/api/comics/\(comicId)/reading-status", body: body)
    }

    // MARK: - Tags & Categories

    func fetchTags() async throws -> [Tag] {
        let resp: TagListResponse = try await get("/api/tags")
        return resp.tags
    }

    func fetchCategories() async throws -> [Category] {
        let resp: CategoryListResponse = try await get("/api/categories")
        return resp.categories
    }

    // MARK: - Groups

    func fetchGroups(contentType: String? = nil) async throws -> [ComicGroup] {
        var params: [String: String]?
        if let t = contentType { params = ["contentType": t] }
        let resp: GroupListResponse = try await get("/api/groups", query: params)
        return resp.groups
    }

    func fetchGroupDetail(id: Int) async throws -> GroupDetailResponse {
        try await get("/api/groups/\(id)")
    }

    /// 返回已分组的漫画 ID 集合
    func fetchComicGroupMap() async throws -> Set<String> {
        let resp: ComicMapResponse = try await get("/api/groups/comic-map")
        return Set(resp.map.keys)
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String]? = nil
    ) async throws -> T {
        guard var components = URLComponents(string: "\(serverURL)\(path)") else {
            throw APIError.invalidURL
        }
        if let query = query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(
        _ path: String,
        body: B
    ) async throws -> T {
        try await performRequest(path: path, method: "POST", body: body)
    }

    private func put<T: Decodable, B: Encodable>(
        _ path: String,
        body: B
    ) async throws -> T {
        try await performRequest(path: path, method: "PUT", body: body)
    }

    private func performRequest<T: Decodable, B: Encodable>(
        path: String,
        method: String,
        body: B
    ) async throws -> T {
        guard let url = URL(string: "\(serverURL)\(path)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        // 处理空响应
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch is DecodingError {
            throw APIError.dataFormat
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError
        }
        if http.statusCode == 401 {
            isLoggedIn = false
            currentUser = nil
            throw APIError.unauthorized
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(http.statusCode, message)
        }
    }
}

// MARK: - 辅助类型

struct EmptyBody: Encodable {}

struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

struct AuthMeResponse: Decodable {
    let user: AuthUser?
    let needsSetup: Bool?
}

struct AuthLoginResponse: Decodable {
    let user: AuthUser
}

struct RatingBody: Encodable {
    let rating: Int?
}

struct PageBody: Encodable {
    let page: Int
}

struct SessionEndBody: Encodable {
    let sessionId: Int
    let endPage: Int
    let duration: Int
}

struct SessionStartBody: Encodable {
    let comicId: String
    let startPage: Int
}

struct ComicMapResponse: Decodable {
    let map: [String: [Int]]
}

enum APIError: LocalizedError {
    case invalidURL
    case networkError
    case unauthorized
    case serverError(Int, String)
    case dataFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .networkError: return "网络连接失败"
        case .unauthorized: return "登录已过期，请重新登录"
        case .serverError(let code, let msg): return "服务器错误 (\(code)): \(msg)"
        case .dataFormat: return "数据格式异常，请检查服务器版本"
        }
    }
}
