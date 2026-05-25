import SwiftUI

// MARK: - 认证图片加载器（替代 Kingfisher，无外部依赖）

struct AuthenticatedImage: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else if isLoading {
                Color(.systemGray6)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            } else {
                Color(.systemGray6)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: url?.absoluteString) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { return }
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // 添加 Cookie 认证
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let img = UIImage(data: data) {
                withAnimation(.easeIn(duration: 0.15)) {
                    self.image = img
                }
            }
        } catch {
            // 静默失败，显示占位图
        }
    }
}

// MARK: - 便捷初始化器

extension AuthenticatedImage {
    init(serverURL: String, comicId: String, thumbnail: Bool = false, page: Int? = nil) {
        if thumbnail {
            self.url = URL(string: "\(serverURL)/api/comics/\(comicId)/thumbnail")
        } else if let page {
            self.url = URL(string: "\(serverURL)/api/comics/\(comicId)/page/\(page)")
        } else {
            self.url = URL(string: "\(serverURL)/api/comics/\(comicId)/thumbnail")
        }
    }
}
