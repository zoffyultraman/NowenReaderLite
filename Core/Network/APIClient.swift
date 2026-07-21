import Foundation
import SwiftUI
import SwiftData
import Network

// MARK: - 统一网络层

@MainActor
@Observable
final class APIClient {
    static let shared = APIClient()

    var serverURL: String = UserDefaults.standard.string(forKey: UserDefaultsKey.serverURL) ?? ""
    var isLoggedIn: Bool = false
    var currentUser: AuthUser?
    /// 断网离线模式：有历史登录记录但服务器不可达
    var isOfflineMode: Bool = false
    /// 网络是否可用（NWPathMonitor 实时更新，初始 false 阻止未检测到状态前的请求）
    private(set) var isNetworkReachable: Bool = false
    /// 网络恢复标记（用于通知 UI 刷新）
    var networkRecovered: Bool = false
    /// 服务器站点名称（从 /api/site-settings 获取，按 serverURL 缓存）
    var siteName: String {
        get { UserDefaults.standard.string(forKey: "siteName_\(serverURL)") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "siteName_\(serverURL)") }
    }
    /// 站点图标 URL（固定端点 /api/site-settings/icon）
    var siteIconURL: URL? {
        guard !serverURL.isEmpty else { return nil }
        return URL(string: "\(serverURL)/api/site-settings/icon")
    }

    /// 用户可访问的书库列表
    var accessibleLibraries: [Library] = []
    /// 当前选中的书库 ID（nil = 全部）
    var selectedLibraryId: String? {
        didSet { UserDefaults.standard.set(selectedLibraryId, forKey: "selectedLibraryId") }
    }
    /// 当前选中书库名称（nil 时返回"全部书库"）
    var selectedLibraryName: String {
        guard let id = selectedLibraryId,
              let lib = accessibleLibraries.first(where: { $0.id == id }) else {
            return "全部书库"
        }
        return lib.name
    }
    /// 当前选中书库类型图标（nil 时返回 grid 图标）
    var selectedLibraryIcon: String {
        guard let id = selectedLibraryId,
              let lib = accessibleLibraries.first(where: { $0.id == id }) else {
            return "square.grid.2x2"
        }
        return libraryIcon(for: lib.type)
    }
    /// 书库类型对应图标
    func libraryIcon(for type: String) -> String {
        switch type {
        case "comic": return "photo.stack"
        case "novel": return "text.book.closed"
        default: return "rectangle.stack"
        }
    }

    private var session: URLSession
    private let cookieStorage = HTTPCookieStorage.shared
    private let pathMonitor = NWPathMonitor()
    private var recoveryMonitorStarted = false

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.selectedLibraryId = UserDefaults.standard.string(forKey: "selectedLibraryId")

        guard !serverURL.isEmpty else { return }

        // 即时恢复登录态，避免闪现登录页（RootRouter 依赖 isLoggedIn）
        if hasLoggedInBefore {
            isLoggedIn = true
        }

        // 先用 NWPathMonitor 快速判断网络状态（无网络时立即进入离线模式）
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            monitor.cancel()  // 只需要首次回调
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    // 有网络，测试服务器是否可达
                    let reachable = await self.testServerReachable()
                    self.isNetworkReachable = reachable
                    if reachable {
                        await self.checkAuth()
                        // 启动时从离线切换到在线，通知 UI 刷新内容
                        self.networkRecovered = true
                    } else if self.hasLoggedInBefore {
                        self.networkRecovered = false
                        self.isOfflineMode = true
                    }
                } else {
                    // 无网络，立即进入离线模式
                    self.isNetworkReachable = false
                    self.networkRecovered = false
                    if self.hasLoggedInBefore {
                        self.isOfflineMode = true
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "StartupNetworkCheck"))
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

    /// 手动设置网络可达状态（首次配置服务器时使用）
    func setNetworkReachable(_ reachable: Bool) {
        isNetworkReachable = reachable
    }

    /// 获取服务器站点信息并缓存
    func fetchSiteSettings() async {
        guard !serverURL.isEmpty, isNetworkReachable else { return }
        // 已有缓存则跳过
        guard siteName.isEmpty else { return }
        do {
            let resp: SiteSettingsResponse = try await get("/api/site-settings")
            if let name = resp.siteName, !name.isEmpty {
                siteName = name
            }
        } catch {
            // 静默失败，不影响主流程
        }
    }

    func testConnection(_ url: String) async -> Bool {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return await withTaskGroup(of: Bool.self) { group in
            // /api/health HEAD
            if let healthURL = URL(string: "\(trimmed)/api/health") {
                group.addTask {
                    var request = URLRequest(url: healthURL)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 2
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode != nil else { return false }
                    return true
                }
            }
            // /api/auth/me GET
            if let authURL = URL(string: "\(trimmed)/api/auth/me") {
                group.addTask {
                    var request = URLRequest(url: authURL)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 2
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse,
                          http.statusCode < 500 else { return false }
                    return true
                }
            }
            for await result in group {
                if result {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Auth

    func checkAuth() async {
        guard !serverURL.isEmpty, isNetworkReachable else { return }
        do {
            let resp: AuthMeResponse = try await get("/api/auth/me")
            if let user = resp.user {
                currentUser = user
                isLoggedIn = true
                isOfflineMode = false
                markHasLoggedInBefore()
                await fetchSiteSettings()
            } else {
                // 服务器明确返回未登录 → 清除历史记录
                isLoggedIn = false
                currentUser = nil
                isOfflineMode = false
                clearHasLoggedInBefore()
            }
        } catch {
            // 网络不可达：区分"从未登录"和"曾经登录但现在断网"
            if hasLoggedInBefore {
                isOfflineMode = true
                isLoggedIn = true   // 保持登录态，允许访问离线内容
            } else {
                isLoggedIn = false
                isOfflineMode = false
            }
            currentUser = nil
        }
    }

    func login(username: String, password: String) async throws -> AuthUser {
        let body = LoginRequest(username: username, password: password)
        let resp: AuthLoginResponse = try await post("/api/auth/login", body: body)
        currentUser = resp.user
        isLoggedIn = true
        isOfflineMode = false
        markHasLoggedInBefore()
        await fetchSiteSettings()
        return resp.user
    }

    func register(username: String, password: String, nickname: String) async throws -> AuthUser {
        let body = RegisterRequest(username: username, password: password, nickname: nickname)
        let resp: AuthLoginResponse = try await post("/api/auth/register", body: body)
        currentUser = resp.user
        isLoggedIn = true
        isOfflineMode = false
        markHasLoggedInBefore()
        return resp.user
    }

    func logout() async {
        do {
            let _: EmptyResponse = try await post("/api/auth/logout", body: EmptyBody())
        } catch {
            AppLogger.error("服务端登出失败: \(error)")
        }
        isLoggedIn = false
        currentUser = nil
        isOfflineMode = false
        clearHasLoggedInBefore()
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

    // MARK: - 历史登录记录（离线模式用）

    private var hasLoggedInBefore: Bool {
        UserDefaults.standard.bool(forKey: "hasLoggedInBefore_\(serverURL)")
    }

    private func markHasLoggedInBefore() {
        UserDefaults.standard.set(true, forKey: "hasLoggedInBefore_\(serverURL)")
    }

    private func clearHasLoggedInBefore() {
        UserDefaults.standard.removeObject(forKey: "hasLoggedInBefore_\(serverURL)")
    }

    // MARK: - 连接测试

    /// 测试服务器是否可达（并发检测两个端点，谁先返回用谁）
    func testServerReachable() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            // /api/health HEAD
            if let url = URL(string: "\(serverURL)/api/health") {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 2
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode != nil else { return false }
                    return true
                }
            }
            // /api/auth/me GET
            if let url = URL(string: "\(serverURL)/api/auth/me") {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 2
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse,
                          http.statusCode < 500 else { return false }
                    return true
                }
            }
            // 任一成功即为可达
            for await result in group {
                if result {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }

    /// 持续网络监听（断线 + 重连都处理，逻辑与启动时一致，永不取消）
    func startNetworkRecovery() {
        guard !recoveryMonitorStarted else { return }
        recoveryMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied {
                    let reachable = await self.testServerReachable()
                    self.isNetworkReachable = reachable
                    if reachable {
                        await self.checkAuth()
                        self.isOfflineMode = false
                        self.networkRecovered = true
                    } else if self.hasLoggedInBefore {
                        self.networkRecovered = false
                        self.isOfflineMode = true
                    }
                } else {
                    self.isNetworkReachable = false
                    self.networkRecovered = false
                    if self.hasLoggedInBefore {
                        self.isOfflineMode = true
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NetworkRecovery"))
    }

    /// 手动重试连接（离线提示按钮调用）
    func retryConnection() async {
        let reachable = await testServerReachable()
        isNetworkReachable = reachable
        if reachable {
            await checkAuth()
            isOfflineMode = false
            networkRecovered = true
        } else {
            networkRecovered = false
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
        let allServers = context.fetchOrLog(FetchDescriptor<ServerRecord>(), label: "删除账号前查询所有服务器")
        for server in allServers where server.boundAccount?.id == account.id {
            server.boundAccount = nil
        }
        context.delete(account)
        context.saveOrLog()
    }

    /// 获取所有已保存账号
    func fetchAllAccounts(context: ModelContext) -> [SavedAccount] {
        context.fetchOrLog(FetchDescriptor<SavedAccount>(), label: "fetchAllAccounts")
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
        category: String? = nil,
        excludeGrouped: Bool? = nil,
        libraryId: String? = nil,
        seriesView: Bool = false
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
        if excludeGrouped == true { params["excludeGrouped"] = "true" }
        if let lid = libraryId ?? selectedLibraryId { params["libraryIds"] = lid }
        if seriesView { params["seriesView"] = "true" }
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

    func updateProgress(comicId: String, page: Int, totalPages: Int? = nil) async throws {
        let body = PageBody(page: page, totalPages: totalPages)
        let _: EmptyResponse = try await put("/api/comics/\(comicId)/progress", body: body)
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

    // MARK: - Reading Activity

    func recordReadingActivity(
        comicId: String,
        clientSessionId: String,
        page: Int,
        totalPages: Int,
        activeSeconds: Int,
        sequence: Int,
        finalize: Bool = false,
        trackProgress: Bool = true
    ) async throws {
        let body = ReadingActivityBody(
            clientSessionId: clientSessionId,
            page: page,
            totalPages: totalPages,
            activeSeconds: activeSeconds,
            sequence: sequence,
            finalize: finalize,
            trackProgress: trackProgress
        )
        let _: EmptyResponse = try await post("/api/reading/\(comicId)/activity", body: body)
    }

    func syncPendingReadingActivities() async {
        guard !isOfflineMode, isNetworkReachable, PendingReadingActivityManager.shared.hasPending else { return }
        let pending = PendingReadingActivityManager.shared.loadAll()
        AppLogger.log("同步离线阅读活动: \(pending.count) 个会话")
        for activity in pending {
            do {
                try await recordReadingActivity(
                    comicId: activity.comicId,
                    clientSessionId: activity.clientSessionId,
                    page: activity.page,
                    totalPages: activity.totalPages,
                    activeSeconds: activity.activeSeconds,
                    sequence: activity.sequence,
                    finalize: activity.finalize,
                    trackProgress: activity.trackProgress
                )
                PendingReadingActivityManager.shared.removeIfSynced(
                    clientSessionId: activity.clientSessionId,
                    sequence: activity.sequence
                )
                AppLogger.log("离线阅读活动已同步: \(activity.comicId) seq=\(activity.sequence)")
            } catch {
                AppLogger.log("离线阅读活动同步失败: \(activity.comicId) \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Stats

    func fetchStats() async throws -> ReadingStats {
        try await get("/api/stats")
    }

    func fetchEnhancedStats() async throws -> EnhancedReadingStats {
        try await get("/api/stats/enhanced")
    }

    func fetchYearlyStats(year: Int? = nil) async throws -> YearlyReadingStats {
        var params: [String: String]?
        if let year { params = ["year": "\(year)"] }
        return try await get("/api/stats/yearly", query: params)
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
        let body = ReadingStatusRequest(status: status)
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
        var hasParams = false
        if let t = contentType {
            params = ["contentType": t]
            hasParams = true
        }
        if let lid = selectedLibraryId {
            if params == nil { params = [:] }
            params!["libraryIds"] = lid
            hasParams = true
        }
        let resp: GroupListResponse = try await get("/api/groups", query: hasParams ? params : nil)
        return resp.groups
    }

    func fetchGroupDetail(id: Int) async throws -> GroupDetailResponse {
        try await get("/api/groups/\(id)")
    }

    // MARK: - Series

    func fetchSeries(search: String? = nil, libraryId: String? = nil) async throws -> [SeriesSummary] {
        var params: [String: String]?
        if let lid = libraryId ?? selectedLibraryId {
            params = ["libraryIds": lid]
        }
        if let search, !search.isEmpty {
            if params == nil { params = [:] }
            params?["search"] = search
        }
        let resp: SeriesListResponse = try await get("/api/series", query: params)
        return resp.series
    }

    func fetchSeriesDetail(id: String) async throws -> SeriesDetailResponse {
        try await get("/api/series/\(id)")
    }

    /// 返回已分组的漫画 ID 集合
    func fetchComicGroupMap() async throws -> Set<String> {
        var params: [String: String]?
        if let lid = selectedLibraryId {
            params = ["libraryIds": lid]
        }
        let resp: ComicMapResponse = try await get("/api/groups/comic-map", query: params)
        return Set(resp.map.keys)
    }

    /// 获取漫画 ID → 合集 ID 列表的完整映射
    func fetchComicGroupMapFull() async throws -> [String: [Int]] {
        var params: [String: String]?
        if let lid = selectedLibraryId {
            params = ["libraryIds": lid]
        }
        let resp: ComicMapResponse = try await get("/api/groups/comic-map", query: params)
        return resp.map
    }

    // MARK: - Libraries

    /// 获取用户可访问的书库列表
    func fetchAccessibleLibraries() async throws -> [Library] {
        let resp: LibraryListResponse = try await get("/api/libraries/accessible")
        accessibleLibraries = resp.libraries
        // 如果当前选中的书库不在可访问列表中，重置为 nil
        if let selectedId = selectedLibraryId,
           !accessibleLibraries.contains(where: { $0.id == selectedId }) {
            selectedLibraryId = nil
        }
        return resp.libraries
    }

    // MARK: - HTTP Methods

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String]? = nil
    ) async throws -> T {
        // 网络不可达时立即失败，不等超时
        guard isNetworkReachable else { throw APIError.networkError }

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
        guard isNetworkReachable else { throw APIError.networkError }
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

struct SiteSettingsResponse: Decodable {
    let siteName: String?
}

struct RatingBody: Encodable {
    let rating: Int?
}

struct PageBody: Encodable {
    let page: Int
    let totalPages: Int?
}

struct ReadingActivityBody: Encodable {
    let clientSessionId: String
    let page: Int
    let totalPages: Int
    let activeSeconds: Int
    let sequence: Int
    let finalize: Bool
    let trackProgress: Bool
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
