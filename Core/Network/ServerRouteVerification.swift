import Foundation

enum ServerRouteVerification: Equatable, Sendable {
    case notConfigured
    case unverified
    case checking
    case verified
    case mismatch
    case authenticationRequired
    case authenticationFailed
    case deferred
    case unavailable
}

struct ServerRouteVerificationReport: Sendable {
    let status: ServerRouteVerification
    var messages: [String] = []

    var message: String? {
        messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

/// 地址配对的身份结果独立于当前可达性保存；超时不能推翻已确认的身份。
struct ServerRouteIdentityCache: Sendable {
    private enum Identity: String, Codable, Sendable {
        case verified
        case mismatch
    }

    private struct Entry: Codable, Sendable {
        let primaryURL: String
        let backupURL: String
        let identity: Identity
    }

    private var entries: [Entry]

    init(data: Data? = nil) {
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    var data: Data? { try? JSONEncoder().encode(entries) }

    func status(primaryURL: String, backupURL: String) -> ServerRouteVerification {
        guard let entry = entries.first(where: {
            $0.primaryURL == primaryURL && $0.backupURL == backupURL
        }) else { return .unverified }
        return entry.identity == .verified ? .verified : .mismatch
    }

    mutating func record(_ status: ServerRouteVerification, primaryURL: String, backupURL: String) {
        let identity: Identity
        switch status {
        case .verified: identity = .verified
        case .mismatch: identity = .mismatch
        default: return
        }
        entries.removeAll { $0.primaryURL == primaryURL && $0.backupURL == backupURL }
        entries.append(Entry(primaryURL: primaryURL, backupURL: backupURL, identity: identity))
    }

    func resolving(
        _ report: ServerRouteVerificationReport, primaryURL: String, backupURL: String
    ) -> ServerRouteVerificationReport {
        guard report.status == .deferred else { return report }
        let knownIdentity = status(primaryURL: primaryURL, backupURL: backupURL)
        let message: String
        switch knownIdentity {
        case .verified:
            message = String(localized: "已保留此前的同一服务器验证结果。暂不可达的线路不影响另一条线路使用。")
        case .mismatch:
            message = String(localized: "此前检测到两条线路身份不一致，仍禁止自动互切。")
        default:
            message = String(localized: "首次验证需要两条线路同时可达；当前可用线路仍可正常使用。")
        }
        return ServerRouteVerificationReport(
            status: knownIdentity == .unverified ? .deferred : knownIdentity,
            messages: [message] + report.messages
        )
    }
}

/// 身份验证只读取用于比较的字段，不依赖书库名称、权限展示等无关字段。
struct ServerRouteFingerprint: Equatable, Sendable {
    let userID: String
    let librarySignatures: [String]

    static func decode(authData: Data, librariesData: Data) throws -> Self? {
        let auth: AuthSnapshot = try decodeResponse(authData, endpoint: "/api/auth/me")
        guard let user = auth.user else { return nil }
        let libraries: LibrariesSnapshot = try decodeResponse(
            librariesData, endpoint: "/api/libraries/accessible"
        )
        return Self(
            userID: user.id,
            librarySignatures: libraries.libraries.map { "\($0.id)|\($0.type)" }.sorted()
        )
    }

    private static func decodeResponse<T: Decodable>(_ data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServerRouteResponseError(
                message: "\(endpoint)：\(ServerRouteDiagnostics.decodingReason(error, data: data))"
            )
        }
    }

    private struct AuthSnapshot: Decodable {
        let user: UserSnapshot?
    }

    private struct UserSnapshot: Decodable {
        let id: String
    }

    private struct LibrariesSnapshot: Decodable {
        let libraries: [LibrarySnapshot]
    }

    private struct LibrarySnapshot: Decodable {
        let id: String
        let type: String
    }
}

struct ServerRouteResponseError: Error, Sendable {
    let message: String
}

enum ServerRouteDiagnostics {
    static func isConnectionUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet,
        ].contains(code)
    }

    static func httpReason(_ statusCode: Int) -> String {
        switch statusCode {
        case 401, 403: return String(localized: "HTTP \(statusCode)：认证被拒绝")
        case 404: return String(localized: "HTTP 404：接口不存在，请检查服务器版本和地址路径")
        case 500...599: return String(localized: "HTTP \(statusCode)：服务器或反向代理出错")
        default: return String(localized: "HTTP \(statusCode)：接口未返回成功响应")
        }
    }

    static func decodingReason(_ error: Error, data: Data) -> String {
        // 只展示结构诊断，避免把响应正文中的凭据或个人信息显示出来。
        if String(data: data.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true {
            return String(localized: "返回了网页而非 JSON，请检查登录跳转或反向代理")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return String(localized: "响应缺少身份字段 \(path)，请检查服务器版本")
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return String(localized: "响应字段 \(path) 的类型不兼容，请检查服务器版本")
        default:
            return String(localized: "响应不是有效的身份验证 JSON")
        }
    }
}
