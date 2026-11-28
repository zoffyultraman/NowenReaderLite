import SwiftUI

// MARK: - 认证图片加载器（替代 Kingfisher，无外部依赖）

@MainActor
private final class AuthenticatedImageLoader {
    static let shared = AuthenticatedImageLoader()

    private struct InFlightEntry {
        var waiters: Int
        let task: Task<UIImage?, Never>
    }

    private var inFlight: [String: InFlightEntry] = [:]

    func loadImage(from url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = await ImageCache.shared.image(forKey: key) {
            return cached
        }

        let task: Task<UIImage?, Never>
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            task = existing.task
        } else {
            let newTask = Task<UIImage?, Never> {
                do {
                    let data = try await APIClient.shared.authenticatedData(from: url)
                    guard !Task.isCancelled else { return nil }
                    let decoded = await Self.decodeOffMain(data)
                    guard !Task.isCancelled, let decoded else { return nil }
                    ImageCache.shared.set(decoded, originalData: data, forKey: key)
                    return decoded
                } catch {
                    return nil
                }
            }
            inFlight[key] = InFlightEntry(waiters: 1, task: newTask)
            task = newTask
        }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, var entry = self.inFlight[key] else { return }
                entry.waiters -= 1
                if entry.waiters <= 0 {
                    self.inFlight.removeValue(forKey: key)
                    entry.task.cancel()
                } else {
                    self.inFlight[key] = entry
                }
            }
        }

        if let entry = inFlight[key], entry.task == task {
            inFlight.removeValue(forKey: key)
        }
        return Task.isCancelled ? nil : result
    }

    private static func decodeOffMain(_ data: Data) async -> UIImage? {
        let decodeTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled, let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }
}

struct AuthenticatedImage: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadedURL: String?

    private let cache = ImageCache.shared

    init(url: URL?) {
        self.url = url
    }

    var body: some View {
        let displayImage = image ?? url.flatMap { cache.memoryImage(forKey: $0.absoluteString) }
        Group {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
            } else if isLoading {
                Color(uiColor: .systemGray6)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            } else {
                Color(uiColor: .systemGray6)
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
        guard let url else {
            image = nil
            loadedURL = nil
            isLoading = false
            return
        }
        let urlString = url.absoluteString
        if loadedURL == urlString, image != nil { return }
        if let memoryHit = cache.memoryImage(forKey: urlString) {
            image = memoryHit
            loadedURL = urlString
            isLoading = false
            return
        }

        image = nil
        loadedURL = urlString
        isLoading = true

        defer {
            if self.url?.absoluteString == urlString {
                isLoading = false
            }
        }

        if let loaded = await AuthenticatedImageLoader.shared.loadImage(from: url) {
            guard !Task.isCancelled, self.url?.absoluteString == urlString else { return }
            if cache.memoryImage(forKey: urlString) != nil && loadedURL == urlString {
                withAnimation(.easeIn(duration: 0.15)) {
                    self.image = loaded
                }
            } else {
                self.image = loaded
            }
        }
    }
}

// MARK: - 便捷初始化器

extension AuthenticatedImage {
    init(serverURL: String, comicId: String, thumbnail: Bool = false, page: Int? = nil) {
        if thumbnail {
            self.init(url: URL(string: "\(serverURL)/api/comics/\(comicId)/thumbnail"))
        } else if let page {
            self.init(url: URL(string: "\(serverURL)/api/comics/\(comicId)/page/\(page)"))
        } else {
            self.init(url: URL(string: "\(serverURL)/api/comics/\(comicId)/thumbnail"))
        }
    }
}
