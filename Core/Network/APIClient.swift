import Foundation
import SwiftUI

// MARK: - 统一网络层

@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    @Published var serverURL: String = UserDefaults.standard.string(forKey: "server_url") ?? ""
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
        serverURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: "server_url")
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
        cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
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
        var components = URLComponents(string: "\(serverURL)\(path)")!
        if let query = query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
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
        if data.isEmpty {
            return EmptyResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .networkError: return "网络连接失败"
        case .unauthorized: return "登录已过期，请重新登录"
        case .serverError(let code, let msg): return "服务器错误 (\(code)): \(msg)"
        }
    }
}
