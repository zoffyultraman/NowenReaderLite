import Foundation

struct Tag: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let color: String?
}

struct TagListResponse: Codable {
    let tags: [Tag]
}

struct Category: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let slug: String?
    let icon: String?
}

struct CategoryListResponse: Codable {
    let categories: [Category]
}
