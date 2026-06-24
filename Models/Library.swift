import Foundation

// MARK: - 书库模型

struct Library: Codable, Identifiable {
    let id: String
    let name: String
    let type: String           // "comic" | "novel" | "mixed"
    let enabled: Bool
    let defaultAccess: String  // "public" | "private"
    let comicCount: Int?
}

struct LibraryListResponse: Codable {
    let libraries: [Library]
}
