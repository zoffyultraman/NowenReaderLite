import re

with open("Core/Services/DownloadManager.swift", "r") as f:
    content = f.read()

# Fix downloadPages
target_pages = """        // 断点续传：找到第一个未下载的页
        var startPage = 0
        for page in 0..<totalPages {
            if !fileManager.isPageDownloaded(comicId: comicId, page: page) {
                startPage = page
                break
            }
        }
        task.completedPages = startPage

        var page = startPage
        while page < totalPages {
            guard task.state == .downloading else { return }
            if Task.isCancelled { return }

            if !hasStorageSpace {
                AppLogger.error("存储空间已满，暂停下载: \\(task.title)")
                task.state = .paused
                refreshStats()
                return
            }

            // 分批并发下载
            let batchEnd = min(page + batchSize, totalPages)
            let batchPages = Array(page..<batchEnd)

            await withTaskGroup(of: (Int, Data?).self) { group in
                for p in batchPages {
                    if fileManager.isPageDownloaded(comicId: comicId, page: p) {
                        continue
                    }
                    group.addTask { [weak self] in
                        guard let self else { return (p, nil) }
                        let data = await self.downloadPage(comicId: comicId, page: p)
                        return (p, data)
                    }
                }

                for await (pageIndex, data) in group {
                    guard task.state == .downloading else { return }
                    if let data {
                        do {
                            try fileManager.savePageData(data, comicId: comicId, page: pageIndex)
                            task.completedPages += 1
                        } catch {
                            AppLogger.error("保存页面失败 \\(comicId)/\\(pageIndex): \\(error)")
                        }
                    }
                }
            }

            refreshStats()
            page = batchEnd
        }

        // 全部完成
        guard task.state == .downloading else { return }
        task.state = .completed"""

replacement_pages = """        // 断点续传：找到第一个未下载的页，并统计已下载的页数
        var downloadedCount = 0
        var firstMissing = -1
        for page in 0..<totalPages {
            if fileManager.isPageDownloaded(comicId: comicId, page: page) {
                downloadedCount += 1
            } else if firstMissing == -1 {
                firstMissing = page
            }
        }
        task.completedPages = downloadedCount
        
        var page = firstMissing == -1 ? totalPages : firstMissing
        while page < totalPages {
            guard task.state == .downloading else { return }
            if Task.isCancelled { return }

            if !hasStorageSpace {
                AppLogger.error("存储空间已满，暂停下载: \\(task.title)")
                task.state = .paused
                refreshStats()
                return
            }

            // 分批并发下载
            let batchEnd = min(page + batchSize, totalPages)
            let batchPages = Array(page..<batchEnd)

            await withTaskGroup(of: (Int, Data?).self) { group in
                for p in batchPages {
                    if fileManager.isPageDownloaded(comicId: comicId, page: p) {
                        continue
                    }
                    group.addTask { [weak self] in
                        guard let self else { return (p, nil) }
                        let data = await self.downloadPage(comicId: comicId, page: p)
                        return (p, data)
                    }
                }

                for await (pageIndex, data) in group {
                    guard task.state == .downloading else { return }
                    if let data {
                        do {
                            try fileManager.savePageData(data, comicId: comicId, page: pageIndex)
                            task.completedPages += 1
                        } catch {
                            AppLogger.error("保存页面失败 \\(comicId)/\\(pageIndex): \\(error)")
                        }
                    }
                }
            }

            refreshStats()
            page = batchEnd
        }

        // 结束检查
        guard task.state == .downloading else { return }
        if task.completedPages >= totalPages {
            task.state = .completed
        } else {
            task.state = .failed
            AppLogger.error("漫画下载失败，部分页面未成功下载: \\(task.title)")
        }"""

if target_pages in content:
    content = content.replace(target_pages, replacement_pages)
else:
    print("target_pages not found")

target_chapters = """        // 断点续传：找到第一个未下载的章节
        var startChapter = 0
        for chapter in 0..<totalChapters {
            if !fileManager.isPageDownloaded(comicId: comicId, page: chapter) {
                startChapter = chapter
                break
            }
        }
        task.completedPages = startChapter

        for chapter in startChapter..<totalChapters {
            guard task.state == .downloading else { return }
            if Task.isCancelled { return }

            if !hasStorageSpace {
                AppLogger.error("存储空间已满，暂停下载: \\(task.title)")
                task.state = .paused
                refreshStats()
                return
            }

            if fileManager.isPageDownloaded(comicId: comicId, page: chapter) {
                continue
            }

            // 下载章节文本内容
            do {
                let content = try await APIClient.shared.fetchChapter(comicId: comicId, index: chapter)
                if let text = content.content, let data = text.data(using: .utf8) {
                    try fileManager.savePageData(data, comicId: comicId, page: chapter)
                    task.completedPages += 1
                    refreshStats()
                }
            } catch {
                AppLogger.error("下载小说章节失败 \\(comicId)/\\(chapter): \\(error)")
            }
        }

        guard task.state == .downloading else { return }
        task.state = .completed"""

replacement_chapters = """        // 断点续传：找到第一个未下载的章节，并统计已下载的章数
        var downloadedCount = 0
        var firstMissing = -1
        for chapter in 0..<totalChapters {
            if fileManager.isPageDownloaded(comicId: comicId, page: chapter) {
                downloadedCount += 1
            } else if firstMissing == -1 {
                firstMissing = chapter
            }
        }
        task.completedPages = downloadedCount
        
        let startChapter = firstMissing == -1 ? totalChapters : firstMissing
        for chapter in startChapter..<totalChapters {
            guard task.state == .downloading else { return }
            if Task.isCancelled { return }

            if !hasStorageSpace {
                AppLogger.error("存储空间已满，暂停下载: \\(task.title)")
                task.state = .paused
                refreshStats()
                return
            }

            if fileManager.isPageDownloaded(comicId: comicId, page: chapter) {
                continue
            }

            // 下载章节文本内容
            do {
                let content = try await APIClient.shared.fetchChapter(comicId: comicId, index: chapter)
                if let text = content.content, let data = text.data(using: .utf8) {
                    try fileManager.savePageData(data, comicId: comicId, page: chapter)
                    task.completedPages += 1
                    refreshStats()
                } else {
                    AppLogger.error("下载小说章节失败: 返回内容为空 \\(comicId)/\\(chapter)")
                }
            } catch {
                AppLogger.error("下载小说章节失败 \\(comicId)/\\(chapter): \\(error)")
            }
        }

        // 结束检查
        guard task.state == .downloading else { return }
        if task.completedPages >= totalChapters {
            task.state = .completed
        } else {
            task.state = .failed
            AppLogger.error("小说下载失败，部分章节未成功下载: \\(task.title)")
        }"""

if target_chapters in content:
    content = content.replace(target_chapters, replacement_chapters)
else:
    print("target_chapters not found")

with open("Core/Services/DownloadManager.swift", "w") as f:
    f.write(content)
print("Done")
