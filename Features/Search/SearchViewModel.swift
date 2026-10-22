import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var results: [Comic] = []
    var isLoading = false
    var errorMessage: String?

    private let isSearchAvailable: @MainActor () -> Bool
    private let fetchComics: @MainActor (String) async throws -> [Comic]
    private var searchTask: Task<Void, Never>?

    init(
        isSearchAvailable: @escaping @MainActor () -> Bool,
        fetchComics: @escaping @MainActor (String) async throws -> [Comic]
    ) {
        self.isSearchAvailable = isSearchAvailable
        self.fetchComics = fetchComics
    }

    func search(immediately: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        errorMessage = nil
        results = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            isLoading = false
            return
        }

        guard isSearchAvailable() else {
            isLoading = false
            errorMessage = "当前处于离线状态，请连接服务器后重试。"
            return
        }

        // 包含输入防抖期间，避免短暂闪出“没有找到结果”。
        isLoading = true

        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            do {
                let comics = try await fetchComics(q)
                if !Task.isCancelled {
                    results = comics
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.error("搜索失败: \(error)")
                    errorMessage = "无法连接服务器，请检查网络后重试。"
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        query = ""
        results = []
        isLoading = false
        errorMessage = nil
    }
}
