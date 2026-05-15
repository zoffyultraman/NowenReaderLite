import Foundation

struct AuthUser: Codable, Identifiable {
    let id: String
    let username: String
    let nickname: String?
    let role: String?
    let aiEnabled: Bool?

    var isAdmin: Bool { role == "admin" }
}

struct LoginRequest: Codable {
    let username: String
    let password: String
}

struct RegisterRequest: Codable {
    let username: String
    let password: String
    let nickname: String
}
