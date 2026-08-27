import Foundation
import SwiftUI
import SwiftData
import Network

// MARK: - 统一网络层

@MainActor
@Observable
final class APIClient {
    static let shared = APIClient()

    /// 服务器身份始终使用主线路；serverURL 是当前实际发出请求的线路。
    private(set) var primaryServerURL: String
    private(set) var backupServerURL: String?
    private(set) var routeMode: ServerRouteMode
    private(set) var serverURL: String
    private(set) var routeVerification: ServerRouteVerification
    private(set) var hasConfiguredAPIKey: Bool
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var cookiePreferredRoutes: Set<String>
    @ObservationIgnored private var isOnLocalNetwork = false
    var isLoggedIn: Bool = false
    var currentUser: AuthUser?
    /// 断网离线模式：有历史登录记录但服务器不可达
    var isOfflineMode: Bool = false
    /// 网络是否可用（NWPathMonitor 实时更新，初始 false 阻止未检测到状态前的请求）
    private(set) var isNetworkReachable: Bool = false
    /// 网络恢复标记（用于通知 UI 刷新）
    var networkRecovered: Bool = false
    /// 服务器站点名称（从 /api/site-settings 获取，按服务器身份缓存）
    var siteName: String {
        get { UserDefaults.standard.string(forKey: "siteName_\(primaryServerURL)") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "siteName_\(primaryServerURL)") }
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
        let defaults = UserDefaults.standard
        let primary = Self.normalizedServerURL(
            defaults.string(forKey: UserDefaultsKey.serverURL) ?? ""
        ) ?? ""
        let backup = defaults.string(forKey: UserDefaultsKey.backupServerURL)
            .flatMap(Self.normalizedServerURL)
        let storedMode = defaults.string(forKey: UserDefaultsKey.serverRouteMode)
            .flatMap(ServerRouteMode.init(rawValue:)) ?? .automatic
        let effectiveMode: ServerRouteMode = backup == nil && storedMode == .backup
            ? .automatic
            : storedMode
        let storedActive = defaults.string(
            forKey: UserDefaultsKey.activeServerRoute(for: primary)
        )
        let allowedRoutes = [primary, backup].compactMap { $0 }

        self.primaryServerURL = primary
        self.backupServerURL = backup
        self.routeMode = effectiveMode
        self.routeVerification = backup == nil ? .notConfigured : .unverified
        let storedAPIKey = KeychainHelper.readAPIKey(for: primary)
        self.apiKey = storedAPIKey
        self.hasConfiguredAPIKey = storedAPIKey != nil
        self.cookiePreferredRoutes = Set(
            defaults.stringArray(
                forKey: UserDefaultsKey.cookiePreferredRoutes(for: primary)
            ) ?? []
        )
        switch effectiveMode {
        case .primary:
            self.serverURL = primary
        case .backup:
            self.serverURL = backup ?? primary
        case .automatic:
            self.serverURL = storedActive.flatMap { allowedRoutes.contains($0) ? $0 : nil } ?? primary
        }

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        self.selectedLibraryId = UserDefaults.standard.string(forKey: "selectedLibraryId")

        guard !serverURL.isEmpty else { return }

        // 即时恢复登录态，避免闪现登录页（RootRouter 依赖 isLoggedIn）
        if hasLocalAuthentication {
            isLoggedIn = true
        }

        // 先用 NWPathMonitor 快速判断网络状态（无网络时立即进入离线模式）
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            monitor.cancel()  // 只需要首次回调
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnLocalNetwork = Self.pathUsesLocalNetwork(path)
                if path.status == .satisfied {
                    // 有网络，测试服务器是否可达
                    let reachable = await self.testServerReachable()
                    self.isNetworkReachable = reachable
                    if reachable {
                        await self.checkAuth()
                        // 启动时从离线切换到在线，通知 UI 刷新内容
                        self.networkRecovered = true
                    } else if self.hasLocalAuthentication {
                        self.networkRecovered = false
                        self.isOfflineMode = true
                    }
                } else {
                    // 无网络，立即进入离线模式
                    self.isNetworkReachable = false
                    self.networkRecovered = false
                    if self.hasLocalAuthentication {
                        self.isOfflineMode = true
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "StartupNetworkCheck"))
    }

    // MARK: - Server

    func setServerURL(_ url: String) {
        configureServerRoutes(
            primaryURL: url,
            backupURL: nil,
            mode: .automatic
        )
    }

    func configureServerRoutes(
        primaryURL: String,
        backupURL: String?,
        mode: ServerRouteMode
    ) {
        guard let primary = Self.normalizedServerURL(primaryURL) else { return }
        let normalizedBackup = backupURL
            .flatMap(Self.normalizedServerURL)
            .flatMap { $0 == primary ? nil : $0 }
        let effectiveMode: ServerRouteMode = normalizedBackup == nil && mode == .backup
            ? .automatic
            : mode
        let isSameProfile = primaryServerURL == primary
        let oldActiveURL = serverURL
        let storedActive = UserDefaults.standard.string(
            forKey: UserDefaultsKey.activeServerRoute(for: primary)
        )
        let allowedRoutes = [primary, normalizedBackup].compactMap { $0 }
        let automaticRoute = [isSameProfile ? oldActiveURL : nil, storedActive, primary]
            .compactMap { $0 }
            .first(where: allowedRoutes.contains) ?? primary
        let targetURL: String
        switch effectiveMode {
        case .automatic: targetURL = automaticRoute
        case .primary: targetURL = primary
        case .backup: targetURL = normalizedBackup ?? primary
        }

        primaryServerURL = primary
        backupServerURL = normalizedBackup
        routeMode = effectiveMode
        routeVerification = normalizedBackup == nil ? .notConfigured : .unverified
        apiKey = KeychainHelper.readAPIKey(for: primary)
        hasConfiguredAPIKey = apiKey != nil
        cookiePreferredRoutes = Set(
            UserDefaults.standard.stringArray(
                forKey: UserDefaultsKey.cookiePreferredRoutes(for: primary)
            ) ?? []
        ).intersection(allowedRoutes)
        UserDefaults.standard.set(primary, forKey: UserDefaultsKey.serverURL)
        UserDefaults.standard.set(normalizedBackup, forKey: UserDefaultsKey.backupServerURL)
        UserDefaults.standard.set(effectiveMode.rawValue, forKey: UserDefaultsKey.serverRouteMode)
        activateRoute(targetURL, copyAuthentication: isSameProfile)
    }

    func matchesServerProfile(_ primaryURL: String) -> Bool {
        Self.normalizedServerURL(primaryURL) == primaryServerURL
    }

    /// 主线路地址变更前迁移客户端本地认证状态，不修改服务端。
    func preparePrimaryRouteChange(from oldURL: String, to newURL: String) {
        guard let oldPrimary = Self.normalizedServerURL(oldURL),
              let newPrimary = Self.normalizedServerURL(newURL),
              oldPrimary != newPrimary else {
            return
        }
        copySessionCookie(from: oldPrimary, to: newPrimary)
        let defaults = UserDefaults.standard
        let oldLoginKey = "hasLoggedInBefore_\(oldPrimary)"
        if defaults.bool(forKey: oldLoginKey) {
            defaults.set(true, forKey: "hasLoggedInBefore_\(newPrimary)")
        }
        if let siteName = defaults.string(forKey: "siteName_\(oldPrimary)") {
            defaults.set(siteName, forKey: "siteName_\(newPrimary)")
        }
    }

    var isUsingBackupRoute: Bool {
        guard let backupServerURL else { return false }
        return serverURL == backupServerURL
    }

    var activeRouteTitle: String {
        isUsingBackupRoute ? "备用线路" : "主线路"
    }

    var activeRouteIsLocal: Bool {
        Self.isLikelyLocalNetworkURL(serverURL)
    }

    var activeAuthenticationTitle: String {
        if hasConfiguredAPIKey, !cookiePreferredRoutes.contains(serverURL) {
            return "API Key"
        }
        return "Cookie"
    }

    @discardableResult
    func setAPIKey(_ value: String?, for serverPrimaryURL: String) -> Bool {
        guard let normalizedURL = Self.normalizedServerURL(serverPrimaryURL) else {
            return false
        }
        let trimmedKey = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let success: Bool
        if let trimmedKey, !trimmedKey.isEmpty {
            success = KeychainHelper.saveAPIKey(trimmedKey, for: normalizedURL)
        } else {
            success = KeychainHelper.deleteAPIKey(for: normalizedURL)
        }
        guard success else { return false }
        if normalizedURL == primaryServerURL {
            apiKey = trimmedKey.flatMap { $0.isEmpty ? nil : $0 }
            hasConfiguredAPIKey = apiKey != nil
        }
        return true
    }

    func testAPIKey(_ value: String, serverURL: String) async throws -> AuthUser {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("nwr_"),
              let baseURL = Self.normalizedServerURL(serverURL),
              let url = URL(string: "\(baseURL)/api/auth/me") else {
            throw APIError.invalidAPIKey
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError
        }
        if http.statusCode == 401 {
            throw APIError.invalidAPIKey
        }
        if !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(http.statusCode, message)
        }
        let auth: AuthMeResponse = try await decode(AuthMeResponse.self, from: data)
        guard let user = auth.user else { throw APIError.invalidAPIKey }
        return user
    }

    private static func normalizedServerURL(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              !host.isEmpty,
              parsed.user == nil else {
            return nil
        }
        return trimmed
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
        guard let trimmed = Self.normalizedServerURL(url) else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            // /api/health HEAD
            if let healthURL = URL(string: "\(trimmed)/api/health") {
                group.addTask {
                    var request = URLRequest(url: healthURL)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 2
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                        return false
                    }
                    return (200..<300).contains(statusCode)
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
                          (200..<300).contains(http.statusCode)
                            || http.statusCode == 401
                            || http.statusCode == 403 else {
                        return false
                    }
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

    /// 使用同一份现有凭据比较两条线路返回的用户与书库身份。
    func verifyServerPair(
        primaryURL: String,
        backupURL: String,
        apiKeyOverride: String? = nil
    ) async -> ServerRouteVerification {
        guard let primary = Self.normalizedServerURL(primaryURL),
              let backup = Self.normalizedServerURL(backupURL),
              primary != backup else {
            return .notConfigured
        }

        let credentials = routeVerificationCredentials(
            primaryURL: primary,
            backupURL: backup,
            apiKeyOverride: apiKeyOverride
        )
        guard !credentials.isEmpty else {
            return .authenticationRequired
        }

        async let primaryFingerprint = fetchServerFingerprint(
            from: primary,
            credentials: credentials
        )
        async let backupFingerprint = fetchServerFingerprint(
            from: backup,
            credentials: credentials
        )
        let (primaryResult, backupResult) = await (
            primaryFingerprint,
            backupFingerprint
        )

        switch (primaryResult, backupResult) {
        case let (.success(primarySnapshot), .success(backupSnapshot)):
            guard primarySnapshot.fingerprint == backupSnapshot.fingerprint else {
                return .mismatch
            }
            updateRouteAuthenticationPreferences(
                primaryURL: primary,
                backupURL: backup,
                primaryUsesCookie: primarySnapshot.usesCookie,
                backupUsesCookie: backupSnapshot.usesCookie
            )
            return .verified
        case (.authenticationFailed, _), (_, .authenticationFailed):
            return .authenticationFailed
        case (.unavailable, _), (_, .unavailable):
            return .unavailable
        }
    }

    @discardableResult
    func refreshRouteVerification() async -> ServerRouteVerification {
        guard let backupServerURL else {
            routeVerification = .notConfigured
            return .notConfigured
        }
        routeVerification = .checking
        let result = await verifyServerPair(
            primaryURL: primaryServerURL,
            backupURL: backupServerURL
        )
        routeVerification = result
        return result
    }

    private func routeVerificationCredentials(
        primaryURL: String,
        backupURL: String,
        apiKeyOverride: String?
    ) -> [ServerRouteCredential] {
        var credentials: [ServerRouteCredential] = []
        let candidateKey: String?
        if let apiKeyOverride {
            let trimmed = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            candidateKey = trimmed.isEmpty ? nil : trimmed
        } else {
            candidateKey = KeychainHelper.readAPIKey(for: primaryURL)
        }
        if let candidateKey {
            credentials.append(.bearer(candidateKey))
        }

        for source in [primaryURL, backupURL] {
            guard let url = URL(string: source) else { continue }
            let sessionCookies = (cookieStorage.cookies(for: url) ?? [])
                .filter { $0.name == "nowen_session" }
            guard !sessionCookies.isEmpty,
                  let cookieHeader = HTTPCookie.requestHeaderFields(
                    with: sessionCookies
                  )["Cookie"] else {
                continue
            }
            credentials.append(.cookie(cookieHeader))
            break
        }
        return credentials
    }

    private func fetchServerFingerprint(
        from baseURL: String,
        credentials: [ServerRouteCredential]
    ) async -> ServerFingerprintResult {
        for credential in credentials {
            let result = await fetchServerFingerprint(
                from: baseURL,
                credential: credential
            )
            switch result {
            case .success:
                return result
            case .authenticationFailed:
                continue
            case .unavailable:
                return .unavailable
            }
        }
        return .authenticationFailed
    }

    private func fetchServerFingerprint(
        from baseURL: String,
        credential: ServerRouteCredential
    ) async -> ServerFingerprintResult {
        guard let authURL = URL(string: "\(baseURL)/api/auth/me"),
              let librariesURL = URL(string: "\(baseURL)/api/libraries/accessible") else {
            return .unavailable
        }

        async let authRequest = fetchVerificationData(
            from: authURL,
            credential: credential
        )
        async let librariesRequest = fetchVerificationData(
            from: librariesURL,
            credential: credential
        )
        let (authResult, librariesResult) = await (authRequest, librariesRequest)

        switch (authResult, librariesResult) {
        case (.authenticationFailed, _), (_, .authenticationFailed):
            return .authenticationFailed
        case let (.success(authData), .success(librariesData)):
            do {
                let auth = try JSONDecoder().decode(AuthMeResponse.self, from: authData)
                guard let user = auth.user else {
                    AppLogger.log("线路验证认证失败: \(baseURL) 未返回登录用户")
                    return .authenticationFailed
                }
                let libraries = try JSONDecoder().decode(
                    LibraryListResponse.self,
                    from: librariesData
                )
                let librarySignatures = libraries.libraries
                    .map { "\($0.id)|\($0.type)" }
                    .sorted()
                return .success(AuthenticatedServerRouteFingerprint(
                    fingerprint: ServerRouteFingerprint(
                        userID: user.id,
                        librarySignatures: librarySignatures
                    ),
                    usesCookie: credential.usesCookie
                ))
            } catch {
                AppLogger.error("线路验证响应解析失败: \(baseURL) \(error.localizedDescription)")
                return .unavailable
            }
        case (.unavailable, _), (_, .unavailable):
            return .unavailable
        }
    }

    private func fetchVerificationData(
        from url: URL,
        credential: ServerRouteCredential
    ) async -> VerificationDataResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch credential {
        case .bearer(let key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .cookie(let value):
            request.setValue(value, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                AppLogger.log("线路验证失败: \(url.host ?? url.absoluteString) 未返回 HTTP 响应")
                return .unavailable
            }
            switch http.statusCode {
            case 200..<300:
                return .success(data)
            case 401, 403:
                AppLogger.log(
                    "线路验证认证失败: \(verificationEndpointDescription(url)) "
                        + "HTTP \(http.statusCode)\(verificationErrorSummary(data))"
                )
                return .authenticationFailed
            default:
                AppLogger.log(
                    "线路验证失败: \(verificationEndpointDescription(url)) "
                        + "HTTP \(http.statusCode)\(verificationErrorSummary(data))"
                )
                return .unavailable
            }
        } catch {
            AppLogger.log(
                "线路验证连接失败: \(verificationEndpointDescription(url)) "
                    + error.localizedDescription
            )
            return .unavailable
        }
    }

    private func verificationEndpointDescription(_ url: URL) -> String {
        let host = url.port.map { "\(url.host ?? "未知主机"):\($0)" }
            ?? url.host
            ?? url.absoluteString
        return "\(host)\(url.path)"
    }

    private func verificationErrorSummary(_ data: Data) -> String {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return ""
        }
        return ": \(text.prefix(160))"
    }

    private func updateRouteAuthenticationPreferences(
        primaryURL: String,
        backupURL: String,
        primaryUsesCookie: Bool,
        backupUsesCookie: Bool
    ) {
        let defaultsKey = UserDefaultsKey.cookiePreferredRoutes(for: primaryURL)
        var preferences = Set(
            UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        )
        if primaryUsesCookie {
            preferences.insert(primaryURL)
            copySessionCookieIfNeeded(to: primaryURL, candidates: [primaryURL, backupURL])
        } else {
            preferences.remove(primaryURL)
        }
        if backupUsesCookie {
            preferences.insert(backupURL)
            copySessionCookieIfNeeded(to: backupURL, candidates: [primaryURL, backupURL])
        } else {
            preferences.remove(backupURL)
        }
        UserDefaults.standard.set(Array(preferences).sorted(), forKey: defaultsKey)
        if primaryURL == primaryServerURL {
            cookiePreferredRoutes = preferences
        }
        if primaryUsesCookie || backupUsesCookie {
            AppLogger.log("部分线路不接受 API Key，已自动改用 Cookie 认证")
        }
    }

    private func copySessionCookieIfNeeded(
        to destinationURL: String,
        candidates: [String]
    ) {
        guard let destination = URL(string: destinationURL) else { return }
        let hasCookie = (cookieStorage.cookies(for: destination) ?? [])
            .contains { $0.name == "nowen_session" }
        guard !hasCookie else { return }
        for sourceURL in candidates where sourceURL != destinationURL {
            guard let source = URL(string: sourceURL),
                  (cookieStorage.cookies(for: source) ?? [])
                    .contains(where: { $0.name == "nowen_session" }) else {
                continue
            }
            copySessionCookie(from: sourceURL, to: destinationURL)
            return
        }
    }

    /// 按当前模式选择可用线路。自动模式优先保留当前线路，失败后再尝试另一条。
    @discardableResult
    func selectReachableRoute() async -> Bool {
        let candidates: [String]
        switch routeMode {
        case .primary:
            candidates = [primaryServerURL]
        case .backup:
            candidates = [backupServerURL].compactMap { $0 }
        case .automatic:
            let verification = await refreshRouteVerification()
            candidates = automaticRouteCandidates(for: verification)
        }

        for candidate in candidates where !candidate.isEmpty {
            if await testConnection(candidate) {
                activateRoute(
                    candidate,
                    copyAuthentication: routeVerification != .mismatch
                )
                isNetworkReachable = true
                return true
            }
        }
        isNetworkReachable = false
        return false
    }

    private func automaticRouteCandidates(
        for verification: ServerRouteVerification
    ) -> [String] {
        guard let backupServerURL else { return [primaryServerURL] }
        if verification == .mismatch {
            return [primaryServerURL]
        }

        let alternate = serverURL == primaryServerURL ? backupServerURL : primaryServerURL
        let stickyOrder = [serverURL, alternate]
        guard verification == .verified else { return stickyOrder }

        let routes = [primaryServerURL, backupServerURL]
        let localRoutes = routes.filter(Self.isLikelyLocalNetworkURL)
        guard localRoutes.count == 1, let localRoute = localRoutes.first else {
            return stickyOrder
        }
        let remoteRoute = routes.first { $0 != localRoute }
        if isOnLocalNetwork {
            return [localRoute, remoteRoute].compactMap { $0 }
        }
        return [remoteRoute, localRoute].compactMap { $0 }
    }

    private func activateRoute(_ newURL: String, copyAuthentication: Bool) {
        guard serverURL != newURL else {
            UserDefaults.standard.set(
                newURL,
                forKey: UserDefaultsKey.activeServerRoute(for: primaryServerURL)
            )
            return
        }
        let previousURL = serverURL
        if copyAuthentication {
            copySessionCookie(from: previousURL, to: newURL)
        }
        serverURL = newURL
        UserDefaults.standard.set(
            newURL,
            forKey: UserDefaultsKey.activeServerRoute(for: primaryServerURL)
        )
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    private func copySessionCookie(from sourceURL: String, to destinationURL: String) {
        guard let source = URL(string: sourceURL),
              let destination = URL(string: destinationURL),
              let destinationHost = destination.host else {
            return
        }
        let sourceCookies = cookieStorage.cookies(for: source) ?? []
        for cookie in sourceCookies where cookie.name == "nowen_session" {
            var properties = cookie.properties ?? [:]
            properties[.domain] = destinationHost
            properties[.originURL] = destination
            properties[.path] = destination.path.isEmpty ? "/" : destination.path
            if destination.scheme?.lowercased() != "https" {
                properties.removeValue(forKey: .secure)
            }
            guard let copiedCookie = HTTPCookie(properties: properties) else { continue }
            cookieStorage.setCookie(copiedCookie)
        }
    }

    private func alternateRoute(afterFailureAt failedURL: String) async -> String? {
        guard routeMode == .automatic,
              routeVerification != .mismatch,
              let backupServerURL else { return nil }
        if serverURL != failedURL {
            return serverURL
        }
        let alternate = failedURL == primaryServerURL ? backupServerURL : primaryServerURL
        guard await testConnection(alternate) else { return nil }
        if serverURL != failedURL {
            return serverURL
        }
        activateRoute(alternate, copyAuthentication: true)
        isNetworkReachable = true
        isOfflineMode = false
        AppLogger.log("线路不可达，已自动切换到\(activeRouteTitle): \(alternate)")
        return alternate
    }

    private static func pathUsesLocalNetwork(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }

    private static func isLikelyLocalNetworkURL(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }

        let ipv4Parts = host.split(separator: ".").compactMap { UInt8($0) }
        if ipv4Parts.count == 4 {
            let first = ipv4Parts[0]
            let second = ipv4Parts[1]
            return first == 10
                || first == 127
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
        }

        let ipv6 = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return ipv6 == "::1"
            || ipv6.hasPrefix("fc")
            || ipv6.hasPrefix("fd")
            || ipv6.hasPrefix("fe8")
            || ipv6.hasPrefix("fe9")
            || ipv6.hasPrefix("fea")
            || ipv6.hasPrefix("feb")
    }

    private func shouldFailover(for error: Error) -> Bool {
        let code: URLError.Code?
        if let urlError = error as? URLError {
            code = urlError.code
        } else {
            let nsError = error as NSError
            code = nsError.domain == NSURLErrorDomain ? URLError.Code(rawValue: nsError.code) : nil
        }
        guard let code else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
        ].contains(code)
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
                await preferLocalRouteAfterAuthentication()
                await fetchSiteSettings()
            } else {
                // 服务器明确返回未登录 → 清除历史记录
                isLoggedIn = false
                currentUser = nil
                isOfflineMode = false
                clearHasLoggedInBefore()
            }
        } catch APIError.unauthorized {
            isLoggedIn = false
            currentUser = nil
            isOfflineMode = false
            clearHasLoggedInBefore()
        } catch {
            // 网络不可达：区分"从未登录"和"曾经登录但现在断网"
            if hasLocalAuthentication {
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
        let resp: AuthLoginResponse = try await post(
            "/api/auth/login",
            body: body,
            retryOnTransportFailure: true,
            usesAuthentication: false
        )
        currentUser = resp.user
        isLoggedIn = true
        isOfflineMode = false
        markHasLoggedInBefore()
        await preferLocalRouteAfterAuthentication()
        await fetchSiteSettings()
        return resp.user
    }

    func register(username: String, password: String, nickname: String) async throws -> AuthUser {
        let body = RegisterRequest(username: username, password: password, nickname: nickname)
        let resp: AuthLoginResponse = try await post(
            "/api/auth/register",
            body: body,
            usesAuthentication: false
        )
        currentUser = resp.user
        isLoggedIn = true
        isOfflineMode = false
        markHasLoggedInBefore()
        await preferLocalRouteAfterAuthentication()
        return resp.user
    }

    private func preferLocalRouteAfterAuthentication() async {
        guard routeMode == .automatic,
              backupServerURL != nil,
              routeVerification != .verified else {
            return
        }
        _ = await selectReachableRoute()
    }

    func logout() async {
        let apiKeyServerURL = hasConfiguredAPIKey ? primaryServerURL : nil
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
        if let apiKeyServerURL {
            _ = setAPIKey(nil, for: apiKeyServerURL)
        }
    }

    /// 清除当前服务器两条线路的 Cookie，不影响其他服务器。
    func clearCookiesForCurrentServer() {
        let hosts = Set(
            [primaryServerURL, backupServerURL]
                .compactMap { $0 }
                .compactMap { URL(string: $0)?.host }
        )
        cookieStorage.cookies?.forEach { cookie in
            if hosts.contains(where: { host in
                cookie.domain == host || cookie.domain.hasSuffix(".\(host)")
            }) {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    // MARK: - 历史登录记录（离线模式用）

    private var hasLoggedInBefore: Bool {
        UserDefaults.standard.bool(forKey: "hasLoggedInBefore_\(primaryServerURL)")
    }

    private var hasLocalAuthentication: Bool {
        hasLoggedInBefore || hasConfiguredAPIKey
    }

    private func markHasLoggedInBefore() {
        UserDefaults.standard.set(true, forKey: "hasLoggedInBefore_\(primaryServerURL)")
    }

    private func clearHasLoggedInBefore() {
        UserDefaults.standard.removeObject(forKey: "hasLoggedInBefore_\(primaryServerURL)")
    }

    // MARK: - 连接测试

    /// 测试服务器是否可达（并发检测两个端点，谁先返回用谁）
    func testServerReachable() async -> Bool {
        await selectReachableRoute()
    }

    /// 持续网络监听（断线 + 重连都处理，逻辑与启动时一致，永不取消）
    func startNetworkRecovery() {
        guard !recoveryMonitorStarted else { return }
        recoveryMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnLocalNetwork = Self.pathUsesLocalNetwork(path)
                if path.status == .satisfied {
                    let reachable = await self.testServerReachable()
                    self.isNetworkReachable = reachable
                    if reachable {
                        await self.checkAuth()
                        self.isOfflineMode = false
                        self.networkRecovered = true
                    } else if self.hasLocalAuthentication {
                        self.networkRecovered = false
                        self.isOfflineMode = true
                    }
                } else {
                    self.isNetworkReachable = false
                    self.networkRecovered = false
                    if self.hasLocalAuthentication {
                        self.isOfflineMode = true
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NetworkRecovery"))
    }

    /// App 回到前台时重新评估自动线路，覆盖网络路径未触发回调的情况。
    func reevaluateAutomaticRoute() async {
        guard routeMode == .automatic, backupServerURL != nil else { return }
        let previousURL = serverURL
        let reachable = await selectReachableRoute()
        isNetworkReachable = reachable
        guard reachable else {
            if hasLocalAuthentication { isOfflineMode = true }
            return
        }
        if serverURL != previousURL {
            await checkAuth()
            networkRecovered = true
        }
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
        let _: EmptyResponse = try await put(
            "/api/comics/\(comicId)/rating",
            body: body,
            retryOnTransportFailure: true
        )
    }

    func updateProgress(comicId: String, page: Int, totalPages: Int? = nil) async throws {
        let body = PageBody(page: page, totalPages: totalPages)
        let _: EmptyResponse = try await put(
            "/api/comics/\(comicId)/progress",
            body: body,
            retryOnTransportFailure: true
        )
    }

    // MARK: - Pages & Content

    func fetchPages(comicId: String) async throws -> PageList {
        try await get(
            "/api/comics/\(comicId)/pages",
            timeout: 120
        )
    }

    func fetchChapter(comicId: String, index: Int) async throws -> ChapterContent {
        try await get(
            "/api/comics/\(comicId)/chapter/\(index)",
            timeout: 120
        )
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

    /// 将 EPUB 章节中的相对资源地址解析到当前线路。
    func serverResourceURL(from source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL = URL(string: serverURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if trimmed.hasPrefix("/") {
            guard let pathComponents = URLComponents(string: trimmed) else { return nil }
            components.percentEncodedPath = pathComponents.percentEncodedPath
            components.percentEncodedQuery = pathComponents.percentEncodedQuery
            components.fragment = pathComponents.fragment
            return components.url
        }
        let base = serverURL.hasSuffix("/") ? serverURL : "\(serverURL)/"
        return URL(string: trimmed, relativeTo: URL(string: base))?.absoluteURL
    }

    /// 创建带 Bearer 或 Cookie 认证的 URLRequest，供图片、PDF 和后台下载复用。
    func authenticatedRequest(url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        applyAuthentication(to: &request)
        return request
    }

    private func applyAuthentication(to request: inout URLRequest) {
        guard let url = request.url else { return }
        let serverBaseURL = currentServerBaseURL(for: url)
        if let serverBaseURL,
           cookiePreferredRoutes.contains(serverBaseURL),
           applyCookies(to: &request, for: url) {
            return
        }
        if let apiKey, serverBaseURL != nil {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return
        }
        _ = applyCookies(to: &request, for: url)
    }

    private func applyCookies(to request: inout URLRequest, for url: URL) -> Bool {
        guard let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty else {
            return false
        }
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (field, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return cookieHeaders["Cookie"] != nil
    }

    private func isCurrentServerResource(_ url: URL) -> Bool {
        currentServerBaseURL(for: url) != nil
    }

    private func currentServerBaseURL(for url: URL) -> String? {
        [primaryServerURL, backupServerURL]
            .compactMap { $0 }
            .first { value in
                guard let baseURL = URL(string: value) else { return false }
                guard url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
                      url.host?.lowercased() == baseURL.host?.lowercased(),
                      url.port == baseURL.port else {
                    return false
                }
                let basePath = baseURL.path.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
                guard !basePath.isEmpty else { return true }
                let normalizedBasePath = "/\(basePath)"
                return url.path == normalizedBasePath
                    || url.path.hasPrefix("\(normalizedBasePath)/")
            }
    }

    /// 加载受保护的图片或 PDF；仅在本服务器资源遇到连接错误时切换线路并重试一次。
    func authenticatedData(from url: URL, timeout: TimeInterval = 15) async throws -> Data {
        let absoluteURL = url.absoluteString
        let knownBase = [primaryServerURL, backupServerURL]
            .compactMap { $0 }
            .first(where: absoluteURL.hasPrefix)
        let isServerResource = knownBase != nil
        let suffix = knownBase.map { String(absoluteURL.dropFirst($0.count)) }

        let (data, response) = try await performTransportRequest(
            allowsFailover: isServerResource
        ) { [self] baseURL in
            let targetURL: URL
            if let suffix, let remappedURL = URL(string: "\(baseURL)\(suffix)") {
                targetURL = remappedURL
            } else {
                targetURL = url
            }
            return authenticatedRequest(url: targetURL, timeout: timeout)
        }
        try validate(response: response, data: data)
        return data
    }

    /// 供后台下载在连接失败后恢复线路；已由其他请求完成切换时也视为恢复成功。
    func recoverRoute(after error: Error, failedResourceURL: URL?) async -> Bool {
        guard shouldFailover(for: error),
              let failedResourceURL else {
            return false
        }
        let absoluteURL = failedResourceURL.absoluteString
        guard let failedBase = [primaryServerURL, backupServerURL]
            .compactMap({ $0 })
            .first(where: absoluteURL.hasPrefix) else {
            return false
        }
        return await alternateRoute(afterFailureAt: failedBase) != nil
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
        let _: EmptyResponse = try await post(
            "/api/reading/\(comicId)/activity",
            body: body,
            retryOnTransportFailure: true
        )
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
        applyAuthentication(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Reading Status

    func updateReadingStatus(comicId: String, status: String) async throws {
        let body = ReadingStatusRequest(status: status)
        let _: EmptyResponse = try await put(
            "/api/comics/\(comicId)/reading-status",
            body: body,
            retryOnTransportFailure: true
        )
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

    func fetchGroups(
        contentType: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        favoritesOnly: Bool = false,
        libraryId: String? = nil
    ) async throws -> [ComicGroup] {
        var params: [String: String]?
        var hasParams = false
        if let t = contentType, !t.isEmpty {
            params = ["contentType": t]
            hasParams = true
        }
        if let category, !category.isEmpty {
            if params == nil { params = [:] }
            params!["category"] = category
            hasParams = true
        }
        if !tags.isEmpty {
            if params == nil { params = [:] }
            params!["tags"] = tags.joined(separator: ",")
            hasParams = true
        }
        if favoritesOnly {
            if params == nil { params = [:] }
            params!["favoritesOnly"] = "true"
            hasParams = true
        }
        if let lid = libraryId ?? selectedLibraryId {
            if params == nil { params = [:] }
            params!["libraryIds"] = lid
            hasParams = true
        }
        let resp: GroupListResponse = try await get("/api/groups", query: hasParams ? params : nil)
        return resp.groups
    }

    func fetchGroupDetail(id: Int, contentType: String? = nil) async throws -> GroupDetailResponse {
        var params: [String: String]?
        if let contentType, !contentType.isEmpty {
            params = ["contentType": contentType]
        }
        return try await get("/api/groups/\(id)", query: params)
    }

    func fetchCatalogItems(
        contentType: String = "comic",
        search: String? = nil,
        page: Int = 1,
        pageSize: Int = 24,
        sortBy: String = "title",
        sortOrder: String = "asc",
        libraryId: String? = nil
    ) async throws -> CatalogItemListResponse {
        var params: [String: String] = [
            "contentType": contentType,
            "page": "\(page)",
            "pageSize": "\(pageSize)",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
        ]
        if let search, !search.isEmpty { params["search"] = search }
        if let lid = libraryId ?? selectedLibraryId { params["libraryIds"] = lid }
        return try await get("/api/catalog/items", query: params)
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

    private func get<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        // 网络不可达时立即失败，不等超时
        guard isNetworkReachable else { throw APIError.networkError }

        let (data, response) = try await performTransportRequest(
            allowsFailover: true
        ) { baseURL in
            guard var components = URLComponents(string: "\(baseURL)\(path)") else {
                throw APIError.invalidURL
            }
            if let query {
                components.queryItems = query.map {
                    URLQueryItem(name: $0.key, value: $0.value)
                }
            }
            guard let url = components.url else { throw APIError.invalidURL }
            var request = URLRequest(url: url)
            if let timeout {
                request.timeoutInterval = timeout
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            applyAuthentication(to: &request)
            return request
        }
        try validate(response: response, data: data)
        return try await decode(T.self, from: data)
    }

    private func post<T: Decodable & Sendable, B: Encodable>(
        _ path: String,
        body: B,
        retryOnTransportFailure: Bool = false,
        usesAuthentication: Bool = true
    ) async throws -> T {
        try await performRequest(
            path: path,
            method: "POST",
            body: body,
            retryOnTransportFailure: retryOnTransportFailure,
            usesAuthentication: usesAuthentication
        )
    }

    private func put<T: Decodable & Sendable, B: Encodable>(
        _ path: String,
        body: B,
        retryOnTransportFailure: Bool = false
    ) async throws -> T {
        try await performRequest(
            path: path,
            method: "PUT",
            body: body,
            retryOnTransportFailure: retryOnTransportFailure,
            usesAuthentication: true
        )
    }

    private func performRequest<T: Decodable & Sendable, B: Encodable>(
        path: String,
        method: String,
        body: B,
        retryOnTransportFailure: Bool,
        usesAuthentication: Bool
    ) async throws -> T {
        guard isNetworkReachable else { throw APIError.networkError }
        let encoder = JSONEncoder()
        let encodedBody = try encoder.encode(body)
        let (data, response) = try await performTransportRequest(
            allowsFailover: retryOnTransportFailure
        ) { baseURL in
            guard let url = URL(string: "\(baseURL)\(path)") else {
                throw APIError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = encodedBody
            if usesAuthentication {
                applyAuthentication(to: &request)
            }
            return request
        }
        try validate(response: response, data: data)

        // 处理空响应
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        return try await decode(T.self, from: data)
    }

    private func performTransportRequest(
        allowsFailover: Bool,
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, URLResponse) {
        let initialURL = serverURL
        do {
            return try await session.data(for: makeRequest(initialURL))
        } catch {
            guard allowsFailover,
                  shouldFailover(for: error),
                  let alternateURL = await alternateRoute(afterFailureAt: initialURL) else {
                throw error
            }
            return try await session.data(for: makeRequest(alternateURL))
        }
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try JSONDecoder().decode(T.self, from: data)
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
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

struct EmptyBody: Encodable, Sendable {}

struct EmptyResponse: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}

struct AuthMeResponse: Decodable, Sendable {
    let user: AuthUser?
    let needsSetup: Bool?
}

struct AuthLoginResponse: Decodable, Sendable {
    let user: AuthUser
}

struct SiteSettingsResponse: Decodable, Sendable {
    let siteName: String?
}

private struct ServerRouteFingerprint: Equatable, Sendable {
    let userID: String
    let librarySignatures: [String]
}

private struct AuthenticatedServerRouteFingerprint: Sendable {
    let fingerprint: ServerRouteFingerprint
    let usesCookie: Bool
}

private enum ServerRouteCredential: Sendable {
    case bearer(String)
    case cookie(String)

    var usesCookie: Bool {
        if case .cookie = self { return true }
        return false
    }
}

private enum ServerFingerprintResult: Sendable {
    case success(AuthenticatedServerRouteFingerprint)
    case authenticationFailed
    case unavailable
}

private enum VerificationDataResult: Sendable {
    case success(Data)
    case authenticationFailed
    case unavailable
}

enum ServerRouteVerification: Equatable, Sendable {
    case notConfigured
    case unverified
    case checking
    case verified
    case mismatch
    case authenticationRequired
    case authenticationFailed
    case unavailable
}

struct RatingBody: Encodable, Sendable {
    let rating: Int?
}

struct PageBody: Encodable, Sendable {
    let page: Int
    let totalPages: Int?
}

struct ReadingActivityBody: Encodable, Sendable {
    let clientSessionId: String
    let page: Int
    let totalPages: Int
    let activeSeconds: Int
    let sequence: Int
    let finalize: Bool
    let trackProgress: Bool
}

struct ComicMapResponse: Decodable, Sendable {
    let map: [String: [Int]]
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidAPIKey
    case secureStorage
    case networkError
    case unauthorized
    case serverError(Int, String)
    case dataFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .invalidAPIKey: return "API Key 无效、已过期或已被撤销"
        case .secureStorage: return "无法访问本机 Keychain"
        case .networkError: return "网络连接失败"
        case .unauthorized: return "登录已过期，请重新登录"
        case .serverError(let code, let msg): return "服务器错误 (\(code)): \(msg)"
        case .dataFormat: return "数据格式异常，请检查服务器版本"
        }
    }
}

extension Notification.Name {
    static let serverRouteDidChange = Notification.Name("serverRouteDidChange")
}
