import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

@MainActor
private final class RouteProbe {
    var replies: [String: CheckedContinuation<ServerRouteLatency, Never>] = [:]
    var verificationCount = 0

    func test(_ url: String) async -> ServerRouteLatency {
        await withCheckedContinuation { replies[url] = $0 }
    }
}

private final class ProbeRequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: Int] = [:]
    private var recordedRequests: [URLRequest] = []
    private var failsConnection = false

    func configure(health: Int = 500, auth: Int = 500, failsConnection: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        statuses = ["/api/health": health, "/api/auth/me": auth]
        recordedRequests = []
        self.failsConnection = failsConnection
    }

    func response(for request: URLRequest) -> Result<Int, URLError> {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        return failsConnection ? .failure(URLError(.timedOut)) : .success(statuses[request.url?.path ?? ""] ?? 404)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = ProbeRequestStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.store.response(for: request) {
        case .success(let status):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
private enum ServerRouteTests {
    private static let local = "http://192.168.1.10:3000"
    private static let remote = "https://reader.example.com"

    @MainActor
    static func main() async throws {
        let addressCount = try addressClassification()
        try fingerprintCompatibility()
        try verificationDiagnostics()
        try identityPersistenceAndTimeout()
        try firstVerificationOutsideLAN()
        try changedRouteRequiresVerification()
        try cachedMismatchAndRealErrors()
        try connectionFailureClassification()
        try await unrelatedWiFi()
        try await reachableLocalRoute()
        try await unavailableLocalRoute()
        try await identityMismatch()
        try await unverifiedIdentity()
        try await publicIPv6()
        try await localRouteThroughVPN()
        try await offlineAndSingleRoute()
        try await restoredIdentityOutsideLAN()
        try await fasterPublicRoute()
        try await latencyHysteresis()
        try await switchCooldown()
        try await measuredResultsAndCachedIdentity()
        try await latencyProbeRequests()
        try await cancelledSelection()
        print("PASS: \(addressCount) address cases, 15 automatic route scenarios, HTTP latency probes, fingerprint compatibility, verification diagnostics and 5 identity cache scenarios")
    }

    private static func identityPersistenceAndTimeout() throws {
        var cache = ServerRouteIdentityCache()
        cache.record(.verified, primaryURL: remote, backupURL: local)
        let restored = ServerRouteIdentityCache(data: cache.data)
        try expect(restored.status(primaryURL: remote, backupURL: local) == .verified, "重启后应恢复已确认的地址配对")
        let report = restored.resolving(
            ServerRouteVerificationReport(status: .deferred, messages: ["备用线路：连接超时"]),
            primaryURL: remote, backupURL: local
        )
        try expect(report.status == .verified, "外网下内网超时不能覆盖此前成功的身份验证")
        try expect(report.message?.contains("已保留此前") == true, "界面应说明使用此前的验证结果")
        try expect(report.message?.contains("备用线路：连接超时") == true, "仍应保留哪条线路当前不可达的详情")
    }

    private static func firstVerificationOutsideLAN() throws {
        var cache = ServerRouteIdentityCache()
        cache.record(.deferred, primaryURL: remote, backupURL: local)
        let restored = ServerRouteIdentityCache(data: cache.data)
        let report = restored.resolving(
            ServerRouteVerificationReport(status: .deferred), primaryURL: remote, backupURL: local
        )
        try expect(report.status == .deferred, "首次在外网验证应等待内网恢复，不能假定身份相同")
        try expect(report.message?.contains("首次验证需要两条线路同时可达") == true, "应解释首次验证的必要条件")
        try expect(restored.status(primaryURL: remote, backupURL: local) == .unverified, "连接超时不能生成成功验证记录")
        let corruptCache = ServerRouteIdentityCache(data: Data("invalid-cache".utf8))
        try expect(corruptCache.status(primaryURL: remote, backupURL: local) == .unverified, "损坏记录应退回未验证状态")
    }

    private static func changedRouteRequiresVerification() throws {
        var cache = ServerRouteIdentityCache()
        cache.record(.verified, primaryURL: remote, backupURL: local)
        let changedPairs = [
            ("https://other.example.com", local),
            (remote, "http://192.168.1.20:3000"),
        ]
        for (primary, backup) in changedPairs {
            try expect(cache.status(primaryURL: primary, backupURL: backup) == .unverified, "任一地址变化后不能沿用另一组地址的身份")
            let report = cache.resolving(
                ServerRouteVerificationReport(status: .deferred), primaryURL: primary, backupURL: backup
            )
            try expect(report.status == .deferred, "新地址不可达时应等待首次验证")
        }
    }

    private static func cachedMismatchAndRealErrors() throws {
        var cache = ServerRouteIdentityCache()
        cache.record(.verified, primaryURL: remote, backupURL: local)
        for status: ServerRouteVerification in [.authenticationFailed, .unavailable] {
            let report = cache.resolving(
                ServerRouteVerificationReport(status: status), primaryURL: remote, backupURL: local
            )
            try expect(report.status == status, "认证、接口或解析异常不能被缓存的验证成功掩盖")
        }
        cache.record(.mismatch, primaryURL: remote, backupURL: local)
        let restored = ServerRouteIdentityCache(data: cache.data)
        let deferred = restored.resolving(
            ServerRouteVerificationReport(status: .deferred), primaryURL: remote, backupURL: local
        )
        try expect(deferred.status == .mismatch, "检测到身份不一致后，超时和重启都不能恢复旧的成功结果")
        cache.record(.verified, primaryURL: remote, backupURL: local)
        try expect(cache.status(primaryURL: remote, backupURL: local) == .verified, "再次实际验证成功后可更新身份结果")
    }

    private static func connectionFailureClassification() throws {
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] {
            try expect(ServerRouteDiagnostics.isConnectionUnavailable(URLError(code)), "连接不可达应延期验证")
        }
        for code: URLError.Code in [.serverCertificateUntrusted, .secureConnectionFailed, .cancelled] {
            try expect(!ServerRouteDiagnostics.isConnectionUnavailable(URLError(code)), "证书、TLS 或取消错误不能被视为普通线路不可达")
        }
    }

    @MainActor
    private static func restoredIdentityOutsideLAN() async throws {
        var cache = ServerRouteIdentityCache()
        cache.record(.verified, primaryURL: remote, backupURL: local)
        let restored = ServerRouteIdentityCache(data: cache.data)
        let selected = await ServerRouteSelector.selectAutomaticRoute(
            primaryURL: remote, backupURL: local, currentURL: local,
            verification: restored.status(primaryURL: remote, backupURL: local),
            measureLatency: { $0 == remote ? .reachable(milliseconds: 100) : .unreachable },
            verifyPair: { throwVerificationFailure() }
        )
        try expect(selected.selectedURL == remote, "在外网重启后应直接使用可达公网线路，不等待内网身份接口")
    }

    private static func fingerprintCompatibility() throws {
        let auth = Data(#"{"user":{"id":"user-a"}}"#.utf8)
        let libraries = Data(#"{"libraries":[{"id":"novels","type":"novel"},{"id":"comics","type":"comic"}]}"#.utf8)
        let minimal = try ServerRouteFingerprint.decode(authData: auth, librariesData: libraries)
        try expect(minimal?.userID == "user-a", "验证不能依赖 username 等非身份字段")
        try expect(minimal?.librarySignatures == ["comics|comic", "novels|novel"], "验证只需书库 ID 和类型，并忽略列表顺序")

        let fullAuth = Data(#"{"user":{"id":"user-a","username":"reader","role":"admin"}}"#.utf8)
        let fullLibraries = Data(#"{"libraries":[{"id":"comics","type":"comic","name":"漫画","enabled":true,"defaultAccess":"private"},{"id":"novels","type":"novel","name":"小说","enabled":true,"defaultAccess":"public"}]}"#.utf8)
        let full = try ServerRouteFingerprint.decode(authData: fullAuth, librariesData: fullLibraries)
        try expect(minimal == full, "服务端多返回或少返回无关展示字段不能导致验证失败")

        let otherUser = try ServerRouteFingerprint.decode(
            authData: Data(#"{"user":{"id":"user-b"}}"#.utf8), librariesData: libraries
        )
        try expect(otherUser != minimal, "不同用户仍须判为不同身份")
        let changedLibrary = try ServerRouteFingerprint.decode(
            authData: auth, librariesData: Data(#"{"libraries":[{"id":"comics","type":"novel"}]}"#.utf8)
        )
        try expect(changedLibrary != minimal, "书库 ID 或类型变化仍须被识别")
        let loggedOut = try ServerRouteFingerprint.decode(
            authData: Data(#"{"user":null}"#.utf8), librariesData: libraries
        )
        try expect(loggedOut == nil, "未登录不能被当作已验证身份")
    }

    private static func verificationDiagnostics() throws {
        let auth = Data(#"{"user":{"id":"user-a"}}"#.utf8)
        let cases: [(Data, String)] = [
            (Data(#"{"libraries":[{"id":"comics"}]}"#.utf8), "type"),
            (Data(#"{"libraries":[{"id":123,"type":"comic"}]}"#.utf8), "类型不兼容"),
            (Data("<html>private-response-secret</html>".utf8), "返回了网页"),
            (Data("not-json-private-response-secret".utf8), "不是有效"),
        ]
        for (data, expected) in cases {
            do {
                _ = try ServerRouteFingerprint.decode(authData: auth, librariesData: data)
                throw TestFailure.assertion("缺少身份字段或格式无效的响应不能通过验证")
            } catch let error as ServerRouteResponseError {
                try expect(error.message.contains("/api/libraries/accessible"), "解析失败必须标明具体接口")
                try expect(error.message.contains(expected), "解析失败必须说明具体原因")
                try expect(!error.message.contains("private-response-secret"), "诊断不能泄露响应正文")
            }
        }
        let report = ServerRouteVerificationReport(
            status: .unavailable, messages: ["主线路：HTTP 404", "备用线路：连接超时"]
        )
        try expect(report.message == "主线路：HTTP 404\n备用线路：连接超时", "应保留主备两条线路的错误")
        try expect(ServerRouteVerificationReport(status: .verified).message == nil, "验证成功时应清除旧错误")
        try expect(ServerRouteDiagnostics.httpReason(404).contains("接口不存在"), "404 应提示检查接口或路径")
        try expect(ServerRouteDiagnostics.httpReason(502).contains("反向代理"), "502 应提示服务器或反向代理问题")
    }

    private static func addressClassification() throws -> Int {
        let cases: [(String, Bool)] = [
            ("http://10.0.0.1", true),
            ("http://127.0.0.1", true),
            ("http://169.254.1.1", true),
            ("http://172.16.0.1", true),
            ("http://172.31.255.254", true),
            ("http://192.168.1.1", true),
            ("http://172.15.0.1", false),
            ("http://172.32.0.1", false),
            ("http://169.253.1.1", false),
            ("http://192.169.1.1", false),
            ("https://8.8.8.8", false),
            ("http://[::1]:3000", true),
            ("http://[0:0:0:0:0:0:0:1]", true),
            ("http://[fc00::1]", true),
            ("http://[FD12:3456::1]", true),
            ("http://[fe80::1%25en0]", true),
            ("http://[febf::1]", true),
            ("http://[fe7f::1]", false),
            ("http://[fec0::1]", false),
            ("https://[2001:4860:4860::8888]", false),
            ("https://[2606:4700:4700::1111]", false),
            ("http://[::ffff:192.168.1.1]", true),
            ("http://[::ffff:c0a8:101]", true),
            ("https://[::ffff:8.8.8.8]", false),
            ("https://[::ffff:808:808]", false),
            ("http://[::]", false),
            ("http://localhost", true),
            ("http://nas", true),
            ("http://reader.local", true),
            ("http://READER.LOCAL.:3000", true),
            ("https://fc.example.com", false),
            ("https://fd.example.com", false),
            ("https://fe8.example.com", false),
            ("https://fe9.example.com", false),
            ("https://fea.example.com", false),
            ("https://feb.example.com", false),
            ("https://reader.example.com", false),
            ("http://10.bad.2.3.4", false),
            ("http://192.168.1.999", false),
            ("http://[fd-invalid]", false),
            ("not a URL", false),
        ]
        for (url, expected) in cases {
            try expect(ServerRouteSelector.isLocalURL(url) == expected, "地址分类错误：\(url)")
        }
        return cases.count
    }

    @MainActor
    private static func unrelatedWiFi() async throws {
        let probe = RouteProbe()
        let selection = Task {
            await ServerRouteSelector.selectAutomaticRoute(
                primaryURL: remote, backupURL: local, currentURL: remote,
                verification: .unverified,
                measureLatency: { await probe.test($0) },
                verifyPair: {
                    probe.verificationCount += 1
                    return .verified
                }
            )
        }
        for _ in 0..<500 {
            if probe.replies.count == 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let startedTogether = probe.replies.count == 2
        if !startedTogether {
            // 释放已开始的请求，避免失败时留下悬挂的 continuation。
            for reply in probe.replies.values { reply.resume(returning: .unreachable) }
            probe.replies.removeAll()
            selection.cancel()
            throw TestFailure.assertion("两条线路必须并发探测，公网请求不能等待内网超时后才开始")
        }
        probe.replies.removeValue(forKey: remote)?.resume(returning: .reachable(milliseconds: 100))
        probe.replies.removeValue(forKey: local)?.resume(returning: .unreachable)
        let selected = await selection.value
        try expect(selected.selectedURL == remote, "其他 Wi-Fi 下内网不可达时应使用公网")
        try expect(selected.latencies[remote]?.milliseconds == 100, "选择结果应保留公网线路的实测延迟")
        try expect(selected.latencies[local] == .unreachable, "选择结果应保留内网不可达状态")
        try expect(probe.verificationCount == 0, "内网不可达时不能继续等待两条线路的身份接口")
    }

    @MainActor
    private static func reachableLocalRoute() async throws {
        for (primary, backup) in [(remote, local), (local, remote)] {
            let selected = await select(primary: primary, backup: backup, reachable: [local, remote])
            try expect(selected == local, "内网延迟明显更低时应使用内网，不受主备顺序影响")
        }
    }

    @MainActor
    private static func unavailableLocalRoute() async throws {
        let selected = await select(current: local, reachable: [remote])
        try expect(selected == remote, "离开内网后应从旧内网线路切换到公网")
    }

    @MainActor
    private static func identityMismatch() async throws {
        let selected = await select(reachable: [local, remote], result: .mismatch)
        try expect(selected == remote, "身份不一致时只能使用主线路")
        let unavailablePrimary = await select(reachable: [local], previous: .mismatch)
        try expect(unavailablePrimary == nil, "已知身份不一致时不能因主线路不可达而切到备用线路")
    }

    @MainActor
    private static func unverifiedIdentity() async throws {
        for result: ServerRouteVerification in [.authenticationRequired, .authenticationFailed, .deferred, .unavailable] {
            let selected = await select(reachable: [local, remote], result: result)
            try expect(selected == remote, "无法确认身份时不能仅凭内网地址抢占当前公网线路")
        }
    }

    @MainActor
    private static func publicIPv6() async throws {
        let ipv6 = "https://[2001:4860:4860::8888]"
        let selected = await select(backup: ipv6, reachable: [remote, ipv6])
        try expect(selected == remote, "公网 IPv6 不能被当成内网而优先切入")
        let domain = "https://fd.example.com"
        let selectedDomain = await select(backup: domain, reachable: [remote, domain])
        try expect(selectedDomain == remote, "以 fd 开头的公网域名不能优先切入")
    }

    @MainActor
    private static func localRouteThroughVPN() async throws {
        let selected = await select(reachable: [local], previous: .verified)
        try expect(selected == local, "内网经 VPN 可达时也应正常使用，无需 Wi-Fi 接口")
    }

    @MainActor
    private static func offlineAndSingleRoute() async throws {
        let offline = await select(reachable: [])
        try expect(offline == nil, "两条线路均不可达时应返回离线")
        let single = await ServerRouteSelector.selectAutomaticRoute(
            primaryURL: remote, backupURL: nil, currentURL: remote, verification: .notConfigured,
            measureLatency: { $0 == remote ? .reachable(milliseconds: 100) : .unreachable },
            verifyPair: { throwVerificationFailure() }
        )
        try expect(single.selectedURL == remote, "单线路应直接探测，不验证线路对")
        try expect(single.latencies.count == 1, "单线路也应返回延迟供设置页显示")
    }

    @MainActor
    private static func fasterPublicRoute() async throws {
        for (primary, backup) in [(remote, local), (local, remote)] {
            let selected = await select(
                primary: primary, backup: backup, current: local, reachable: [local, remote],
                milliseconds: [local: 200, remote: 30]
            )
            try expect(selected == remote, "公网明显更快时应选择公网，不能固定优先内网或主线路")
        }
        let unverified = await select(
            current: local, reachable: [local, remote], result: .authenticationFailed,
            milliseconds: [local: 200, remote: 30]
        )
        try expect(unverified == local, "身份未通过验证时，延迟更低也不能抢占当前可达线路")
    }

    @MainActor
    private static func latencyHysteresis() async throws {
        let cases: [(Double, Double, String)] = [
            (100, 85, remote), (100, 81, remote), (100, 80, local),
            (1_000, 850, remote), (1_000, 800, local),
            (12, 1, remote), (100, 100, remote), (100, 150, remote),
        ]
        for (current, candidate, expected) in cases {
            let selected = await select(
                reachable: [local, remote], milliseconds: [remote: current, local: candidate]
            )
            try expect(selected == expected, "必须同时满足至少快 20 ms 和 20%，平局或小幅波动应保持当前连接")
        }
        let initial = await select(
            current: "https://old.example.com", reachable: [local, remote],
            milliseconds: [remote: 12, local: 10], allowsLatencySwitch: false
        )
        try expect(initial == local, "没有当前可达线路时应直接选择最低延迟，无需满足切换阈值")
        for invalid in [Double.nan, .infinity, -1] {
            let selected = await select(
                reachable: [local, remote], milliseconds: [remote: 100, local: invalid]
            )
            try expect(selected == remote, "非有限数或负延迟不能被选为可用线路")
        }
    }

    @MainActor
    private static func switchCooldown() async throws {
        let stable = await select(
            reachable: [local, remote], milliseconds: [remote: 200, local: 10],
            allowsLatencySwitch: false
        )
        try expect(stable == remote, "切换后 30 秒内应保持仍可达的当前连接")
        let failed = await select(current: local, reachable: [remote], allowsLatencySwitch: false)
        try expect(failed == remote, "当前线路不可达时必须绕过冷却，立即选择可用线路")
        let mismatch = await select(
            current: local, reachable: [local], previous: .mismatch, allowsLatencySwitch: false
        )
        try expect(mismatch == nil, "故障切换不能绕过已知身份不一致的限制")
    }

    @MainActor
    private static func measuredResultsAndCachedIdentity() async throws {
        let result = await ServerRouteSelector.selectAutomaticRoute(
            primaryURL: remote, backupURL: local, currentURL: remote, verification: .verified,
            measureLatency: { .reachable(milliseconds: $0 == local ? 10 : 200) },
            verifyPair: { throwVerificationFailure() }
        )
        try expect(result.selectedURL == local, "已验证身份应直接参与延迟选择，无需每轮重复验证")
        try expect(result.latencies[local]?.milliseconds == 10, "应保留备用线路延迟")
        try expect(result.latencies[remote]?.milliseconds == 200, "应保留主线路延迟")
        let mismatched = await ServerRouteSelector.selectAutomaticRoute(
            primaryURL: remote, backupURL: local, currentURL: local, verification: .mismatch,
            measureLatency: { .reachable(milliseconds: $0 == local ? 1 : 500) },
            verifyPair: { throwVerificationFailure() }
        )
        try expect(mismatched.selectedURL == remote, "已知身份不一致时只能使用主线路")
        try expect(mismatched.latencies.count == 2, "禁止互切时仍应显示两条线路的实测延迟")
    }

    private static func latencyProbeRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (health, auth, isReachable) in [(204, 500, true), (405, 401, true), (401, 403, true), (500, 404, false), (401, 500, false)] {
            ProbeURLProtocol.store.configure(health: health, auth: auth)
            let result = await ServerRouteProbe.measure(remote, session: session)
            try expect((result.milliseconds != nil) == isReachable, "健康检查或认证端点的有效响应才能用于测速")
            let requests = ProbeURLProtocol.store.requests
            try expect(!requests.isEmpty, "测速应发出实际请求")
            for request in requests {
                try expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "测速必须绕过本地和远端缓存")
                try expect(request.timeoutInterval == 2, "不可达线路必须有较短超时")
                try expect(request.httpMethod == (request.url?.path == "/api/health" ? "HEAD" : "GET"), "探测方法应兼容旧版服务端")
            }
        }
        ProbeURLProtocol.store.configure(failsConnection: true)
        let failed = await ServerRouteProbe.measure(remote, session: session)
        try expect(failed == .unreachable, "连接超时必须显示不可达，不能生成虚假的低延迟")
        ProbeURLProtocol.store.configure()
        for invalid in ["", "file:///etc/hosts", "https://user:password@example.com"] {
            let result = await ServerRouteProbe.measure(invalid, session: session)
            try expect(result == .unreachable, "无效地址或包含凭据的地址不应参与测速")
        }
        try expect(ProbeURLProtocol.store.requests.isEmpty, "无效地址不能发出网络请求")
    }

    @MainActor
    private static func cancelledSelection() async throws {
        let task = Task {
            await ServerRouteSelector.selectAutomaticRoute(
                primaryURL: remote, backupURL: local, currentURL: remote, verification: .unverified,
                measureLatency: { _ in .reachable(milliseconds: 10) },
                verifyPair: { throwVerificationFailure() }
            )
        }
        task.cancel()
        let result = await task.value
        try expect(result.selectedURL == nil, "取消的旧测速不能再产生切换结果或触发身份验证")
    }

    private static func throwVerificationFailure() -> ServerRouteVerification {
        fatalError("单线路、已有身份结果或已取消时不应调用线路对验证")
    }

    @MainActor
    private static func select(
        primary: String = remote,
        backup: String = local,
        current: String = remote,
        reachable: Set<String>,
        previous: ServerRouteVerification = .unverified,
        result: ServerRouteVerification = .verified,
        milliseconds: [String: Double] = [:],
        allowsLatencySwitch: Bool = true
    ) async -> String? {
        let selection = await ServerRouteSelector.selectAutomaticRoute(
            primaryURL: primary, backupURL: backup, currentURL: current, verification: previous,
            allowsLatencySwitch: allowsLatencySwitch,
            measureLatency: {
                reachable.contains($0)
                    ? .reachable(milliseconds: milliseconds[$0] ?? ($0 == local ? 20 : 200))
                    : .unreachable
            },
            verifyPair: { result }
        )
        return selection.selectedURL
    }
}
