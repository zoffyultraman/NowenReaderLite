import Foundation
import Darwin

enum ServerRouteLatency: Equatable, Sendable {
    case reachable(milliseconds: Double)
    case unreachable

    var milliseconds: Double? {
        guard case .reachable(let value) = self, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct ServerRouteSelection: Sendable {
    let selectedURL: String?
    let latencies: [String: ServerRouteLatency]
}

enum ServerRouteProbe {
    /// 测量实际 HTTP 响应时间；不使用缓存，也不依赖 ICMP 或网络接口类型。
    static func measure(_ baseURL: String, session: URLSession = .shared) async -> ServerRouteLatency {
        guard let components = URLComponents(string: baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil,
              !Task.isCancelled else { return .unreachable }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return await withTaskGroup(of: ServerRouteLatency.self) { group in
            for (path, method) in [("/api/health", "HEAD"), ("/api/auth/me", "GET")] {
                guard let url = URL(string: base + path) else { continue }
                group.addTask {
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                    request.httpMethod = method
                    request.timeoutInterval = 2
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let clock = ContinuousClock()
                    let start = clock.now
                    guard let (_, response) = try? await session.data(for: request),
                          !Task.isCancelled,
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode)
                            || (method == "GET" && [401, 403].contains(http.statusCode)) else {
                        return .unreachable
                    }
                    let elapsed = start.duration(to: clock.now).components
                    let milliseconds = Double(elapsed.seconds) * 1_000
                        + Double(elapsed.attoseconds) / 1_000_000_000_000_000
                    return .reachable(milliseconds: milliseconds)
                }
            }
            for await result in group where result.milliseconds != nil {
                group.cancelAll()
                return result
            }
            return .unreachable
        }
    }
}

enum ServerRouteSelector {
    static let reevaluationInterval: Duration = .seconds(30)

    @MainActor
    static func selectAutomaticRoute(
        primaryURL: String,
        backupURL: String?,
        currentURL: String,
        verification: ServerRouteVerification,
        allowsLatencySwitch: Bool = true,
        measureLatency: @MainActor @Sendable (String) async -> ServerRouteLatency,
        verifyPair: @MainActor () async -> ServerRouteVerification
    ) async -> ServerRouteSelection {
        let latencies = await measureRoutes(
            primaryURL: primaryURL, backupURL: backupURL, measureLatency: measureLatency
        )
        guard !Task.isCancelled else {
            return ServerRouteSelection(selectedURL: nil, latencies: latencies)
        }
        let primaryReachable = latencies[primaryURL]?.milliseconds != nil
        guard let backupURL else {
            return ServerRouteSelection(
                selectedURL: primaryReachable ? primaryURL : nil, latencies: latencies
            )
        }
        let backupReachable = latencies[backupURL]?.milliseconds != nil
        // 已确认的身份可复用；不可达时不再等待身份接口超时。
        let needsVerification = verification != .verified && verification != .mismatch
        let effectiveVerification = primaryReachable && backupReachable && needsVerification
            ? await verifyPair()
            : verification
        let selectedURL: String?
        if effectiveVerification == .mismatch {
            selectedURL = primaryReachable ? primaryURL : nil
        } else {
            let reachable = [primaryURL, backupURL].filter { latencies[$0]?.milliseconds != nil }
            let current = reachable.first(where: { $0 == currentURL })
            if effectiveVerification == .verified,
               let fastest = reachable.min(by: {
                   (latencies[$0]?.milliseconds ?? .infinity) < (latencies[$1]?.milliseconds ?? .infinity)
               }) {
                if let current, let currentMS = latencies[current]?.milliseconds,
                   let fastestMS = latencies[fastest]?.milliseconds {
                    // 同时要求快至少 20 ms 和 20%；冷却期间仍允许不可达时故障切换。
                    let improvement = currentMS - fastestMS
                    selectedURL = allowsLatencySwitch && improvement >= max(20, currentMS * 0.2)
                        ? fastest : current
                } else {
                    selectedURL = fastest
                }
            } else {
                selectedURL = current ?? reachable.first
            }
        }
        return ServerRouteSelection(
            selectedURL: Task.isCancelled ? nil : selectedURL, latencies: latencies
        )
    }

    @MainActor
    static func measureRoutes(
        primaryURL: String,
        backupURL: String?,
        measureLatency: @MainActor @Sendable (String) async -> ServerRouteLatency
    ) async -> [String: ServerRouteLatency] {
        guard let backupURL, backupURL != primaryURL else {
            return [primaryURL: await measureLatency(primaryURL)]
        }
        async let primaryProbe = measureLatency(primaryURL)
        async let backupProbe = measureLatency(backupURL)
        let (primary, backup) = await (primaryProbe, backupProbe)
        return [primaryURL: primary, backupURL: backup]
    }

    static func isLocalURL(_ value: String) -> Bool {
        guard var host = URLComponents(string: value)?.host?.lowercased() else { return false }
        let isBracketed = host.hasPrefix("[") && host.hasSuffix("]")
        if isBracketed {
            host = String(host.dropFirst().dropLast())
        }
        let address = host.contains(":")
            ? host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            : host

        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { isLocalIPv4(Array($0)) }
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocalIPv4(Array(bytes.suffix(4)))
            }
            let isLoopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }

        // 必须先排除 IP 字面量，再判断主机名；IPv6 前缀不能用于匹配域名。
        guard !isBracketed, !host.contains(":"), !host.contains("%") else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return !host.isEmpty
            && (host == "localhost" || host.hasSuffix(".local") || !host.contains("."))
    }

    private static func isLocalIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 10
            || bytes[0] == 127
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }
}
