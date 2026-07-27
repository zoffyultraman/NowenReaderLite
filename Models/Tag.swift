import Foundation

struct Tag: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let color: String?
}

struct TagListResponse: Codable, Sendable {
    let tags: [Tag]
}

struct Category: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let slug: String?
    let icon: String?
}

struct CategoryListResponse: Codable, Sendable {
    let categories: [Category]
}
