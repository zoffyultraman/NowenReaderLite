import Foundation
import Observation

private final class SearchTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func replace(with newTask: Task<Void, Never>?) {
        lock.lock()
        let previous = task
        task = newTask
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        replace(with: nil)
    }
}

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var results: [Comic] = []
    var isLoading = false
    var errorMessage: String?

    private let isSearchAvailable: @MainActor () -> Bool
    private let fetchComics: @MainActor (String) async throws -> [Comic]
    private let taskStore = SearchTaskStore()

    init(
        isSearchAvailable: @escaping @MainActor () -> Bool,
        fetchComics: @escaping @MainActor (String) async throws -> [Comic]
    ) {
        self.isSearchAvailable = isSearchAvailable
        self.fetchComics = fetchComics
    }

    deinit {
        taskStore.cancel()
    }

    func search(immediately: Bool = false) {
        taskStore.cancel()
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

        let task = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            do {
                let comics = try await self.fetchComics(q)
                if !Task.isCancelled {
                    self.results = comics
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.error("搜索失败: \(error)")
                    self.errorMessage = "无法连接服务器，请检查网络后重试。"
                }
            }
            if !Task.isCancelled {
                self.isLoading = false
            }
        }
        taskStore.replace(with: task)
    }

    func clear() {
        taskStore.cancel()
        query = ""
        results = []
        isLoading = false
        errorMessage = nil
    }
}
