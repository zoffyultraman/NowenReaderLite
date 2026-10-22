import Foundation
import Darwin

enum ServerRouteSelector {
    /// 网络接口类型不能证明服务器位于当前局域网，以实际探测结果为准。
    @MainActor
    static func selectAutomaticRoute(
        primaryURL: String,
        backupURL: String?,
        currentURL: String,
        verification: ServerRouteVerification,
        testConnection: @MainActor @Sendable (String) async -> Bool,
        verifyPair: @MainActor () async -> ServerRouteVerification
    ) async -> String? {
        guard let backupURL else {
            return await testConnection(primaryURL) ? primaryURL : nil
        }

        async let primaryProbe = testConnection(primaryURL)
        async let backupProbe = testConnection(backupURL)
        let (primaryReachable, backupReachable) = await (primaryProbe, backupProbe)

        // 任一线路不可达时无需等待身份接口超时，沿用已有验证结果。
        let effectiveVerification = primaryReachable && backupReachable
            ? await verifyPair()
            : verification
        if effectiveVerification == .mismatch {
            return primaryReachable ? primaryURL : nil
        }

        let reachableRoutes = [(primaryURL, primaryReachable), (backupURL, backupReachable)]
            .filter { $0.1 }
            .map { $0.0 }
        if effectiveVerification == .verified {
            let localRoutes = reachableRoutes.filter(isLocalURL)
            if localRoutes.count == 1 {
                return localRoutes[0]
            }
        }
        // 未确认身份或地址分类不明确时，保留当前可达线路，避免反复切换。
        return reachableRoutes.first(where: { $0 == currentURL }) ?? reachableRoutes.first
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
