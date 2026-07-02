import re

with open("Core/Services/DownloadManager.swift", "r") as f:
    content = f.read()

target = """        // 全部完成
        guard task.state == .downloading else { return }
        task.state = .completed
        refreshStats()

        // 同步到 SwiftData
        syncToStore(task: task)

        AppLogger.log("漫画下载完成: \\(task.title) (\\(totalPages)页)")
    }"""

replacement = """        // 结束检查
        guard task.state == .downloading else { return }
        
        // 重新准确统计一遍本地真实已下载的页数，防止遗漏
        var finalDownloadedCount = 0
        for p in 0..<totalPages {
            if fileManager.isPageDownloaded(comicId: comicId, page: p) {
                finalDownloadedCount += 1
            }
        }
        task.completedPages = finalDownloadedCount
        
        if task.completedPages >= totalPages {
            task.state = .completed
            AppLogger.log("漫画下载完成: \\(task.title) (\\(totalPages)页)")
        } else {
            task.state = .failed
            AppLogger.error("漫画下载失败，部分页面未成功下载: \\(task.title)")
        }
        
        refreshStats()

        // 同步到 SwiftData
        syncToStore(task: task)
    }"""

if target in content:
    with open("Core/Services/DownloadManager.swift", "w") as f:
        f.write(content.replace(target, replacement))
    print("Success")
else:
    print("target not found")
