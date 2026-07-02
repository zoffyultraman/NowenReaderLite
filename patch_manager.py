import re

with open("Core/Services/DownloadManager.swift", "r") as f:
    code = f.read()

# 1. Class definition
code = code.replace("final class DownloadManager: NSObject, URLSessionDownloadDelegate {", "final class DownloadManager {")

# 2. Add SessionDelegate instance
code = code.replace(
    "@ObservationIgnored private lazy var backgroundSession: URLSession = {",
    "@ObservationIgnored private lazy var sessionDelegate = SessionDelegate(manager: self)\n\n    @ObservationIgnored private lazy var backgroundSession: URLSession = {"
)

# 3. Change delegate
code = code.replace("delegate: self", "delegate: sessionDelegate")

# 4. Change init
code = code.replace("private override init() {", "private init() {")
code = code.replace("super.init()\n        // 提前访问一下", "// 提前访问一下")

# 5. Remove URLSessionDownloadDelegate methods from DownloadManager and add to SessionDelegate
# We'll just rename them inside DownloadManager so they are normal methods.
code = code.replace("nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL)", "func handleDownloadFinished(downloadTask: URLSessionDownloadTask, location: URL)")

code = code.replace("nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)", "func handleTaskCompleted(task: URLSessionTask, error: Error?)")

code = code.replace("nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession)", "func handleBackgroundEventsFinished()")

# 6. Add SessionDelegate class at the end
delegate_code = """

// MARK: - SessionDelegate

final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var manager: DownloadManager?
    
    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must bounce to MainActor if we want to call MainActor methods safely.
        // Or we can just let handleDownloadFinished run on MainActor.
        Task { @MainActor in
            manager?.handleDownloadFinished(downloadTask: downloadTask, location: location)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            manager?.handleTaskCompleted(task: task, error: error)
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            manager?.handleBackgroundEventsFinished()
        }
    }
}
"""

code += delegate_code

# Wait, in DownloadManager, handleDownloadFinished had its own `Task { @MainActor in }` inside it.
# We should remove that inner task since we are calling it from Task {@MainActor} in the delegate!
# Let's clean up the nested tasks in DownloadManager.
# Actually, if handleDownloadFinished is @MainActor, we can just leave its internal Task or remove it.
# Let's remove the nested `Task { @MainActor in` in handleDownloadFinished and handleTaskCompleted.

# handleDownloadFinished
code = code.replace("""        // 因为 BackgroundSession 设置了 delegateQueue: .main，所以这里是主线程
        // 但由于是在 nonisolated 方法中，需要调度
        Task { @MainActor in
            do {""", "        do {")

code = code.replace("""            } catch {
                AppLogger.error("处理下载文件失败 \\(comicId)/\\(index): \\(error)")
            }
        }""", """            } catch {
                AppLogger.error("处理下载文件失败 \\(comicId)/\\(index): \\(error)")
            }""")

# handleTaskCompleted
code = code.replace("""        Task { @MainActor in
            guard let downloadTask = self.tasks[comicId] else { return }""", """        guard let downloadTask = self.tasks[comicId] else { return }""")

code = code.replace("""            // 或者更简单：每次任务结束，我们就重新核算本地文件数，如果全下完了就标记完成
            self.checkTaskCompletion(for: comicId)
        }""", """            // 或者更简单：每次任务结束，我们就重新核算本地文件数，如果全下完了就标记完成
            self.checkTaskCompletion(for: comicId)""")

# handleBackgroundEventsFinished
code = code.replace("""        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }""", """        self.backgroundCompletionHandler?()
        self.backgroundCompletionHandler = nil""")

with open("Core/Services/DownloadManager.swift", "w") as f:
    f.write(code)

