import Foundation

struct AuthUser: Codable, Identifiable, Sendable {
    let id: String
    let username: String
    let nickname: String?
    let role: String?
    let aiEnabled: Bool?

    var isAdmin: Bool { role == "admin" }
}

struct LoginRequest: Codable, Sendable {
    let username: String
    let password: String
}

struct RegisterRequest: Codable, Sendable {
    let username: String
    let password: String
    let nickname: String
}
