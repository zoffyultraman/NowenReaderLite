import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw TestFailure.assertion(message)
}

@MainActor
private final class MockWarmupClient: ReaderWarmupClient {
    struct Request {
        let comicId: String
        let body: ReaderWarmupBody
    }

    var readerServerIdentity = "server-a"
    var readerSessionIdentity: String? = "server-a|user-a"
    var isReaderWarmupAvailable = true
    var response = ReaderWarmupResponse(sessionActive: true, sessionTtlSeconds: 120)
    var nextError: Error?
    var blockNext = false
    var pendingReply: CheckedContinuation<ReaderWarmupResponse, Error>?
    var requests: [Request] = []
    var endedIds: [String] = []

    func warmupReaderPages(comicId: String, body: ReaderWarmupBody) async throws -> ReaderWarmupResponse {
        requests.append(Request(comicId: comicId, body: body))
        if let error = nextError {
            nextError = nil
            throw error
        }
        if blockNext {
            blockNext = false
            return try await withCheckedThrowingContinuation { pendingReply = $0 }
        }
        return response
    }

    func endReaderWarmup(comicId: String, sessionId: String) async throws {
        endedIds.append(sessionId)
    }
}

@main
private enum APICompatibilityTests {
    @MainActor
    static func main() async throws {
        try metadataCompatibility()
        try phase1ModelsCompatibility()
        try phase2CloudSyncCompatibility()
        try phase3NovelSearchCompatibility()
        try phase4ManagementAndBrandingCompatibility()
        try requestEncoding()
        try await foregroundLifecycle()
        try await heartbeatAndNovel()
        try await inactiveEntry()
        try await offlineRecovery()
        try await offlineLaunchAuthentication()
        try await legacyServer()
        try await missingEndpoint()
        try await lateRequestAndResume()
        try await identityChange()
        try await retryPrefetch()
        try await uncertainProbe()
        try await searchFailureAndRetry()
        try await searchCancellation()
        try await offlineAndDebouncedSearch()
        print("PASS: 20 API compatibility, Phase 1/2/3/4 models, reader lifecycle and search scenarios")
    }

    @MainActor
    private static func searchFailureAndRetry() async throws {
        var shouldFail = true
        let model = SearchViewModel(isSearchAvailable: { true }) { _ in
            if shouldFail { throw URLError(.timedOut) }
            return []
        }
        model.query = "作品"
        model.search(immediately: true)
        try expect(model.isLoading && model.errorMessage == nil, "请求开始时应显示处理中")
        try await eventually("搜索失败应结束加载", { !model.isLoading })
        try expect(model.errorMessage != nil, "网络失败不能伪装成无结果")

        shouldFail = false
        model.search(immediately: true)
        try expect(model.errorMessage == nil, "重试应清除旧错误")
        try await eventually("重试成功应结束加载", { !model.isLoading })
        try expect(model.results.isEmpty && model.errorMessage == nil, "成功的空结果应与失败区分")
    }

    @MainActor
    private static func searchCancellation() async throws {
        var replies: [String: CheckedContinuation<[Comic], Error>] = [:]
        var completed: Set<String> = []
        let model = SearchViewModel(isSearchAvailable: { true }) { query in
            defer { completed.insert(query) }
            return try await withCheckedThrowingContinuation { replies[query] = $0 }
        }
        model.query = "旧查询"
        model.search(immediately: true)
        try await eventually("旧查询应已发出", { replies["旧查询"] != nil })
        model.query = "新查询"
        model.search(immediately: true)
        try await eventually("新查询应已发出", { replies["新查询"] != nil })

        replies.removeValue(forKey: "旧查询")?.resume(throwing: URLError(.timedOut))
        try await eventually("旧查询应已返回", { completed.contains("旧查询") })
        await Task.yield()
        try expect(model.isLoading && model.errorMessage == nil, "旧请求的错误不能中断新查询")

        let comic = try JSONDecoder().decode(Comic.self, from: Data(
            #"{"id":"result","title":"新结果","pageCount":1,"lastReadPage":0,"isFavorite":false}"#.utf8
        ))
        replies.removeValue(forKey: "新查询")?.resume(returning: [comic])
        try await eventually("新结果应展示", { !model.isLoading })
        try expect(model.results == [comic], "应保留最新查询结果")

        model.query = "取消查询"
        model.search(immediately: true)
        try await eventually("取消前查询应已发出", { replies["取消查询"] != nil })
        model.clear()
        replies.removeValue(forKey: "取消查询")?.resume(returning: [comic])
        try await eventually("取消后的请求应已返回", { completed.contains("取消查询") })
        await Task.yield()
        try expect(model.results.isEmpty && !model.isLoading && model.errorMessage == nil,
                   "退出搜索后，迟到响应不能恢复结果或错误")
    }

    @MainActor
    private static func offlineAndDebouncedSearch() async throws {
        var isAvailable = false
        var requestCount = 0
        let model = SearchViewModel(isSearchAvailable: { isAvailable }) { _ in
            requestCount += 1
            return []
        }
        model.query = "作品"
        model.search(immediately: true)
        try expect(model.errorMessage != nil && !model.isLoading && requestCount == 0,
                   "离线搜索应立即解释原因，且不发请求")

        isAvailable = true
        model.search()
        try expect(model.isLoading && model.errorMessage == nil, "防抖期间应保持处理中状态")
        model.clear()
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(requestCount == 0, "清除搜索应取消尚未发出的防抖请求")
        model.query = " \n "
        model.search(immediately: true)
        try expect(!model.isLoading && model.errorMessage == nil && requestCount == 0,
                   "空白查询应保持空状态")
    }

    @MainActor
    private static func metadataCompatibility() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(GroupDetailResponse.self, from: Data(#"{"id":1,"name":"旧合集"}"#.utf8))
        try expect(legacy.tagItems == nil && legacy.categories == nil, "旧合集缺省字段应兼容")
        let modern = try decoder.decode(GroupDetailResponse.self, from: Data(##"{"id":1,"name":"合集","tags":"旧字符串字段","tagItems":[{"id":2,"name":"冒险","color":"#fff"}],"categories":[{"id":3,"name":"漫画","slug":"comic","count":4}],"seriesList":null,"comics":null}"##.utf8))
        try expect(modern.tagItems?.first?.name == "冒险", "合集应读取 tagItems 而不是 tags 字符串")
        try expect(modern.categories?.first?.slug == "comic", "合集应读取分类")
        let roundTrip = try decoder.decode(GroupDetailResponse.self, from: JSONEncoder().encode(modern))
        try expect(roundTrip.tagItems == modern.tagItems && roundTrip.categories == modern.categories, "合集元数据应可往返保存")

        var summary: [String: Any] = [
            "id": "series-a", "libraryId": "library-a", "rootRelativePath": "a", "title": "目录作品",
            "itemCount": 2, "sectionCount": 0, "completedItemCount": 0, "totalReadTime": 0,
            "fileSize": 0, "isFavorite": false, "manualLocked": false, "createdAt": "", "updatedAt": "",
        ]
        let oldSeries = try decoder.decode(SeriesSummary.self, from: JSONSerialization.data(withJSONObject: summary))
        try expect(oldSeries.categories == nil, "旧目录作品应兼容缺省分类")
        summary["categories"] = [["id": 7, "name": "连载", "slug": "serial"]]
        summary["tags"] = [["id": 8, "name": "奇幻"]]
        let newSeries = try decoder.decode(SeriesSummary.self, from: JSONSerialization.data(withJSONObject: summary))
        try expect(newSeries.categories?.first?.name == "连载" && newSeries.tags?.first?.name == "奇幻", "目录作品应解码标签和分类")

        let oldOffline = try decoder.decode(OfflineGroupMeta.self, from: Data(#"{"id":1,"name":"离线合集","comicIds":["comic-a"]}"#.utf8))
        try expect(oldOffline.tagItems == nil && oldOffline.categories == nil, "旧离线记录应兼容新字段")
        let newOffline = OfflineGroupMeta(id: 1, name: "离线合集", coverUrl: nil, author: nil, description: nil, comicCount: 1, sortOrder: nil, tagItems: modern.tagItems, categories: modern.categories, comicIds: ["comic-a"])
        let savedOffline = try decoder.decode(OfflineGroupMeta.self, from: JSONEncoder().encode(newOffline))
        try expect(savedOffline.tagItems == modern.tagItems && savedOffline.categories == modern.categories, "离线保存应保留新字段")
    }

    @MainActor
    private static func phase1ModelsCompatibility() throws {
        let decoder = JSONDecoder()

        let multiEditionJSON = #"""
        {
            "id": "book-epub",
            "title": "三体",
            "filename": "three-body.epub",
            "pageCount": 32,
            "fileSize": 2048000,
            "lastReadPage": 5,
            "lastReadPositionRatio": 0.42,
            "readingStatus": "reading",
            "isFavorite": true,
            "type": "novel",
            "libraryId": "lib-novel",
            "canDownload": true,
            "format": "epub",
            "formats": ["epub", "pdf", "txt"],
            "editionCount": 3,
            "preferredComicId": "book-epub",
            "fileLocation": {
                "libraryId": "lib-novel",
                "libraryName": "小说库",
                "filename": "three-body.epub",
                "relativePath": "科幻/三体/three-body.epub",
                "relativeDir": "科幻/三体",
                "baseName": "three-body",
                "format": "epub",
                "canDownload": true,
                "canManage": false
            },
            "editions": [
                {
                    "comicId": "book-epub",
                    "title": "三体",
                    "format": "epub",
                    "editionLabel": "精排版",
                    "isCurrent": true,
                    "isPreferred": true,
                    "fileSize": 2048000,
                    "pageCount": 32,
                    "lastReadPage": 5,
                    "lastReadAt": "2026-11-20T10:00:00Z",
                    "readingStatus": "reading",
                    "downloadUrl": "/api/comics/book-epub/download",
                    "fileLocation": {
                        "libraryId": "lib-novel",
                        "libraryName": "小说库",
                        "filename": "three-body.epub",
                        "relativePath": "科幻/三体/three-body.epub",
                        "relativeDir": "科幻/三体",
                        "baseName": "three-body",
                        "format": "epub",
                        "canDownload": true
                    }
                },
                {
                    "comicId": "book-pdf",
                    "title": "三体",
                    "format": "pdf",
                    "isCurrent": false,
                    "fileSize": 8048000,
                    "pageCount": 420,
                    "lastReadPage": 0,
                    "fileLocation": {
                        "libraryId": "lib-novel",
                        "libraryName": "小说库",
                        "filename": "three-body.pdf",
                        "relativePath": "科幻/三体/three-body.pdf",
                        "relativeDir": "科幻/三体",
                        "baseName": "three-body",
                        "format": "pdf",
                        "canDownload": false
                    }
                }
            ]
        }
        """#
        let book = try decoder.decode(Comic.self, from: Data(multiEditionJSON.utf8))
        try expect(book.formatBadge == "EPUB +2", "多格式角标应显示主格式与额外格式数")
        try expect(book.lastReadPositionRatio == 0.42, "应解码阅读位置比例")
        try expect(book.canDownloadOriginalFile, "非文件夹且具备权限时允许导出原文件")
        try expect(book.resolvedEditions.count == 2, "应解码多格式版本数组")
        try expect(book.resolvedEditions[1].isPdf && !book.resolvedEditions[1].canDownloadOriginalFile,
                   "应识别 PDF 版本及各自下载权限")

        let seriesShelfJSON = #"""
        {
            "id": "series-001",
            "title": "海贼王",
            "filename": "__series__.cbz",
            "pageCount": 1,
            "comicCount": 1,
            "lastReadPage": 0,
            "lastReadAt": "2026-11-20T12:00:00Z",
            "isFavorite": false,
            "type": "comic"
        }
        """#
        let seriesShelf = try decoder.decode(Comic.self, from: Data(seriesShelfJSON.utf8))
        try expect(seriesShelf.isSeriesShelfItem, "应识别目录作品虚拟书架项")
        try expect(seriesShelf.formatBadge.isEmpty, "目录作品虚拟书架项不展示单册格式角标")
        try expect(seriesShelf.progress == 0, "单章节目录作品未读完时不应误算为 100%")

        let realFileNamedSeriesJSON = #"""
        {
            "id": "series-real-book",
            "title": "Series Special",
            "filename": "series-special.cbz",
            "pageCount": 10,
            "lastReadPage": 0,
            "isFavorite": false
        }
        """#
        let realBook = try decoder.decode(Comic.self, from: Data(realFileNamedSeriesJSON.utf8))
        try expect(!realBook.isSeriesShelfItem && realBook.formatBadge == "CBZ",
                   "非 __series__.cbz 的作品不应误判为目录虚拟项，且应从 filename 提取格式")

        let librariesJSON = #"""
        {
            "libraries": [
                {
                    "id": "lib-comic",
                    "name": "日漫库",
                    "type": "comic",
                    "seriesDepth": 3,
                    "enabled": true,
                    "defaultAccess": "private",
                    "comicCount": 120,
                    "shelfCount": 42,
                    "canManage": true
                },
                {
                    "id": "lib-novel",
                    "name": "轻小说",
                    "type": "novel",
                    "seriesDepth": 3,
                    "comicCount": 30
                }
            ]
        }
        """#
        let libResponse = try decoder.decode(LibraryListResponse.self, from: Data(librariesJSON.utf8))
        try expect(libResponse.libraries.count == 2, "应解码书库列表")
        try expect(libResponse.libraries[0].logicalCount == 42 && libResponse.libraries[0].supportsDirectoryCategories,
                   "漫画库 seriesDepth > 1 应支持目录分类并展示 shelfCount")
        try expect(libResponse.libraries[1].logicalCount == 30 && !libResponse.libraries[1].supportsDirectoryCategories,
                   "小说库不启用漫画目录分类且缺失 shelfCount 时回退 comicCount")

        let dirsJSON = #"""
        {
            "libraryId": "lib-comic",
            "seriesDepth": 3,
            "maxDirectoryDepth": 2,
            "parent": "少年漫",
            "breadcrumbs": [{"name": "少年漫", "path": "少年漫"}],
            "directories": [
                {
                    "name": "热血",
                    "path": "少年漫/热血",
                    "depth": 2,
                    "workCount": 18,
                    "hasChildren": false,
                    "coverUrl": "/api/comics/c1/thumbnail"
                }
            ],
            "total": 1,
            "page": 1,
            "pageSize": 100,
            "totalPages": 1
        }
        """#
        let dirs = try decoder.decode(LibraryDirectoryListResponse.self, from: Data(dirsJSON.utf8))
        try expect(dirs.breadcrumbs.first?.path == "少年漫" && dirs.directories.first?.workCount == 18,
                   "应正确解码物理目录节点与面包屑")

        let seriesItemJSON = #"""
        {
            "comic": {
                "id": "vol-1",
                "title": "第 1 卷",
                "pageCount": 180,
                "lastReadPage": 0,
                "isFavorite": false
            },
            "sortIndex": 1,
            "displayLabel": "第 1 卷",
            "formats": ["CBZ", "PDF"],
            "editionCount": 2,
            "editions": [
                {"comicId": "vol-1", "format": "cbz", "isCurrent": true},
                {"comicId": "vol-1-pdf", "format": "pdf", "isCurrent": false}
            ]
        }
        """#
        let seriesItem = try decoder.decode(SeriesItem.self, from: Data(seriesItemJSON.utf8))
        try expect(seriesItem.formatBadge == "CBZ +1" && seriesItem.resolvedEditions.count == 2,
                   "目录分卷应正确解码多格式版本信息")
    }

    @MainActor
    private static func phase2CloudSyncCompatibility() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let bookmarkListJSON = #"""
        {
            "bookmarks": [
                {
                    "id": "bm-1",
                    "userId": "user-1",
                    "comicId": "novel-1",
                    "pageIndex": 12,
                    "positionRatio": 1.35,
                    "chapterTitle": "第十二章",
                    "name": "重要转折",
                    "note": "伏笔回收",
                    "createdAt": 1730000000000,
                    "updatedAt": 1730000005000
                }
            ]
        }
        """#
        let bookmarks = try decoder.decode(BookmarkListResponse.self, from: Data(bookmarkListJSON.utf8)).bookmarks
        try expect(bookmarks.count == 1 && bookmarks[0].positionRatio == 1.0,
                   "书签 positionRatio 应严格限定在 0.0...1.0")
        let bmRoundTrip = try decoder.decode(UserBookmark.self, from: encoder.encode(bookmarks[0]))
        try expect(bmRoundTrip == bookmarks[0], "UserBookmark 应支持 Equatable 与编码往返")

        let highlightSingleJSON = #"""
        {
            "highlight": {
                "id": "hl-1",
                "comicId": "novel-1",
                "chapterIndex": 3,
                "chapterTitle": "第三章",
                "text": "给岁月以文明，而不是给文明以岁月。",
                "note": "经典台词",
                "color": ""
            }
        }
        """#
        let highlight = try decoder.decode(HighlightSingleResponse.self, from: Data(highlightSingleJSON.utf8)).highlight
        try expect(highlight.color == "#fbbf24" && highlight.startOffset == -1,
                   "缺省 color 与 startOffset 应回落到 #fbbf24 与 -1")
        let hlRoundTrip = try decoder.decode(UserHighlight.self, from: encoder.encode(highlight))
        try expect(hlRoundTrip == highlight, "UserHighlight 应支持 Equatable 与编码往返")

        let prefsJSON = #"""
        {
            "globalComic": {
                "direction": "rtl",
                "isRTL": true,
                "fitMode": "fit",
                "pageGap": 8
            },
            "globalNovel": {
                "fontSize": 19.5,
                "darkMode": true,
                "theme": "night"
            },
            "seriesOverride": null,
            "comicOverride": {
                "direction": "ltr",
                "fitMode": "fill"
            },
            "resolvedComic": {
                "direction": "ltr",
                "isRTL": true,
                "fitMode": "fill",
                "extra": null
            }
        }
        """#
        let prefs = try decoder.decode(ScopedReaderPreferences.self, from: Data(prefsJSON.utf8))
        try expect(prefs.globalComic["direction"]?.stringValue == "rtl"
                   && prefs.globalComic["isRTL"]?.boolValue == true
                   && prefs.globalComic["pageGap"]?.intValue == 8,
                   "应正确解析 globalComic 各类标量偏好值")
        try expect(prefs.globalNovel["fontSize"]?.doubleValue == 19.5
                   && prefs.globalNovel["darkMode"]?.boolValue == true,
                   "应正确解析 globalNovel 字号与深色模式")
        try expect(prefs.seriesOverride == nil
                   && prefs.comicOverride?["fitMode"]?.stringValue == "fill"
                   && prefs.resolvedComic["direction"]?.stringValue == "ltr",
                   "应正确解析 scoped override 与 resolvedComic")
        let prefsRoundTrip = try decoder.decode(ScopedReaderPreferences.self, from: encoder.encode(prefs))
        try expect(prefsRoundTrip == prefs, "ScopedReaderPreferences 应支持往返编解码与相等比较")

        let legacyProgressData = Data(#"{"page":5,"totalPages":20,"updatedAt":0}"#.utf8)
        let legacyProgress = try decoder.decode(PendingProgressManager.PendingRecord.self, from: legacyProgressData)
        try expect(legacyProgress.positionRatio == nil && legacyProgress.page == 5,
                   "旧版 PendingRecord 缺省 positionRatio 时应兼容解码")
        let ratioProgress = PendingProgressManager.PendingRecord(
            page: 5,
            totalPages: 20,
            positionRatio: 0.25,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let decodedRatioProgress = try decoder.decode(
            PendingProgressManager.PendingRecord.self,
            from: encoder.encode(ratioProgress)
        )
        try expect(decodedRatioProgress.positionRatio == 0.25, "PendingRecord 应保留 positionRatio")

        let testSessionId = "test-session-\(UUID().uuidString)"
        PendingReadingActivityManager.shared.save(
            comicId: "novel-test",
            clientSessionId: testSessionId,
            page: 4,
            totalPages: 10,
            positionRatio: 1.5,
            activeSeconds: 30,
            sequence: 1,
            finalize: false,
            trackProgress: true
        )
        let savedActivity = PendingReadingActivityManager.shared
            .loadAll()
            .first { $0.clientSessionId == testSessionId }
        try expect(savedActivity?.positionRatio == 1.0,
                   "PendingReadingActivityManager 应将 positionRatio clamp 到 1.0")
        PendingReadingActivityManager.shared.removeIfSynced(clientSessionId: testSessionId, sequence: 1)

        let testComicId = "novel-record-test-\(UUID().uuidString)"
        ReadingRecordManager.shared.save(
            comicId: testComicId,
            chapter: 2,
            page: 3,
            totalPages: 9,
            positionRatio: -0.2
        )
        let savedRecord = ReadingRecordManager.shared.load(comicId: testComicId)
        try expect(savedRecord?.totalPages == 9 && savedRecord?.positionRatio == 0.0,
                   "ReadingRecordManager 应保存 totalPages 并将 positionRatio clamp 到 0.0")
        ReadingRecordManager.shared.remove(comicId: testComicId)
    }

    @MainActor
    private static func phase3NovelSearchCompatibility() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let searchJSON = #"""
        {
            "query": "黑暗森林",
            "totalChapters": 45,
            "matchedChapters": 2,
            "totalMatches": 5,
            "truncated": true,
            "results": [
                {
                    "chapterIndex": 8,
                    "chapterTitle": "第八章 猜疑链",
                    "matchText": "...宇宙就是一座黑暗森林，每个文明都是带枪的猎人...",
                    "matchCount": 3
                },
                {
                    "chapterIndex": 15,
                    "chapterTitle": "第十五章 技术爆炸",
                    "matchText": "...在黑暗森林法则的威慑下...",
                    "matchCount": 2
                }
            ]
        }
        """#
        let decoded = try decoder.decode(NovelSearchResponse.self, from: Data(searchJSON.utf8))
        try expect(decoded.query == "黑暗森林"
                   && decoded.totalChapters == 45
                   && decoded.matchedChapters == 2
                   && decoded.totalMatches == 5
                   && decoded.truncated == true
                   && decoded.results.count == 2,
                   "应正确解码服务端小说全书搜索响应与统计信息")
        try expect(decoded.results[0].id == 8 && decoded.results[0].matchCount == 3,
                   "NovelSearchResultItem.id 应映射到 chapterIndex")
        let roundTrip = try decoder.decode(NovelSearchResponse.self, from: encoder.encode(decoded))
        try expect(roundTrip == decoded, "NovelSearchResponse 应支持往返编解码与相等比较")

        let partialItem = try decoder.decode(NovelSearchResultItem.self, from: Data(#"{}"#.utf8))
        try expect(partialItem.chapterIndex == 0
                   && partialItem.chapterTitle.isEmpty
                   && partialItem.matchText.isEmpty
                   && partialItem.matchCount == 0,
                   "NovelSearchResultItem 缺失字段时应安全回退默认值")

        let partialResp = try decoder.decode(NovelSearchResponse.self, from: Data(#"{"query":"测试"}"#.utf8))
        try expect(partialResp.query == "测试"
                   && partialResp.truncated == false
                   && partialResp.results.isEmpty,
                   "NovelSearchResponse 缺失字段时应安全回退默认值")
    }

    @MainActor
    private static func phase4ManagementAndBrandingCompatibility() throws {
        let decoder = JSONDecoder()

        let adminJSON = Data(#"{"id":"u1","username":"admin","nickname":"站长","role":"admin","aiEnabled":true}"#.utf8)
        let normalJSON = Data(#"{"id":"u2","username":"reader","nickname":"读者","role":"user","aiEnabled":false}"#.utf8)
        let adminUser = try decoder.decode(AuthUser.self, from: adminJSON)
        let normalUser = try decoder.decode(AuthUser.self, from: normalJSON)
        try expect(adminUser.isAdmin && adminUser.nickname == "站长", "管理员身份与昵称应正确解码")
        try expect(!normalUser.isAdmin && normalUser.nickname == "读者", "普通用户身份与昵称应正确解码")

        let managedComicJSON = #"""
        {
            "id": "comic-del-1",
            "title": "待管理漫画",
            "pageCount": 24,
            "lastReadPage": 0,
            "isFavorite": false,
            "canManage": true,
            "tags": [{"id": 1, "name": "科幻"}, {"id": 2, "name": "完结"}]
        }
        """#
        let managedComic = try decoder.decode(Comic.self, from: Data(managedComicJSON.utf8))
        try expect(managedComic.canManage == true && managedComic.tags?.map(\.name) == ["科幻", "完结"],
                   "作品 canManage 权限与可点击 Tag 列表应正确解码")

        let managedSeriesJSON = #"""
        {
            "id": "series-del-1",
            "libraryId": "lib-1",
            "rootRelativePath": "科幻/系列A",
            "title": "系列A",
            "itemCount": 3,
            "sectionCount": 1,
            "completedItemCount": 1,
            "totalReadTime": 120,
            "fileSize": 102400,
            "isFavorite": false,
            "manualLocked": false,
            "canManage": true,
            "createdAt": "2026-11-21T00:00:00Z",
            "updatedAt": "2026-11-21T00:00:00Z",
            "tags": [{"id": 5, "name": "机甲"}]
        }
        """#
        let managedSeries = try decoder.decode(SeriesSummary.self, from: Data(managedSeriesJSON.utf8))
        try expect(managedSeries.canManage == true && managedSeries.tags?.first?.name == "机甲",
                   "目录系列 canManage 权限与标签应正确解码")
    }

    @MainActor
    private static func requestEncoding() throws {
        let body = ReaderWarmupBody(sessionId: "reader-a", startPage: 4, count: -1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        try expect(json?["sessionId"] as? String == "reader-a", "请求应使用 sessionId")
        try expect(json?["count"] as? Int == -1 && json?["startPage"] as? Int == 4, "续期参数应符合 API")
        let legacy = try JSONDecoder().decode(ReaderWarmupResponse.self, from: Data(#"{"success":true}"#.utf8))
        try expect(legacy.sessionActive == nil && legacy.sessionTtlSeconds == nil, "应可识别旧版响应")
    }

    @MainActor
    private static func foregroundLifecycle() async throws {
        let client = MockWarmupClient()
        let session = ReaderWarmupSession(client: client)
        session.start(comicId: "comic-a", page: 0, totalPages: 10, preheatPages: true, isActive: true)
        try await eventually("进入应先续期", { client.requests.count == 1 })
        try expect(client.requests[0].body.count == -1, "当前页加载前不能抢先解压后续页")
        session.pageDidLoad(0)
        try await eventually("进入应续期并预热", { client.requests.count == 2 })
        let id = client.requests[0].body.sessionId
        try expect(client.requests[0].body.count == -1, "先探测租约，不能先执行解压")
        try expect(client.requests[1].body.startPage == 1 && client.requests[1].body.count == 8, "应预热之后 8 页")
        session.updatePage(3, totalPages: 10)
        session.pageDidLoad(3)
        session.updatePage(4, totalPages: 10)
        session.pageDidLoad(4)
        try await eventually("移动到下一段应预热", { client.requests.count == 3 })
        try expect(client.requests[2].body.startPage == 5 && client.requests[2].body.count == 5, "预热不能越界")
        session.setActive(false)
        try await eventually("切后台应释放原会话", { client.endedIds == [id] })
        session.setActive(true)
        try await eventually("恢复应重新建立会话", { client.requests.count == 5 })
        try expect(client.requests[3].body.sessionId != id, "恢复必须使用新 ID")
        await session.stop()?.value
        try expect(client.endedIds.count == 2, "每次会话只释放一次")
        await session.stop()?.value
        try expect(client.endedIds.count == 2, "重复停止不能多次释放")
    }

    @MainActor
    private static func heartbeatAndNovel() async throws {
        let client = MockWarmupClient()
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 20_000_000)
        session.start(comicId: "novel-a", page: 2, totalPages: 20, preheatPages: false, isActive: true)
        session.updatePage(3, totalPages: 20)
        try await eventually("小说阅读应持续续期", { client.requests.count >= 3 })
        try expect(client.requests.allSatisfy { $0.body.count == -1 }, "小说/PDF 只能续期，不能预热图片")
        try expect(client.requests.last?.body.startPage == 3, "心跳应携带最新章节")
        await session.stop()?.value
        let count = client.requests.count
        try await Task.sleep(nanoseconds: 60_000_000)
        try expect(client.requests.count == count, "停止后不能再发送心跳")
    }

    @MainActor
    private static func inactiveEntry() async throws {
        let client = MockWarmupClient()
        let session = ReaderWarmupSession(client: client)
        session.start(comicId: "comic-a", page: 99, totalPages: 10, preheatPages: true, isActive: false)
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(client.requests.isEmpty, "后台完成加载不能创建租约")
        session.setActive(true)
        try await eventually("回到前台应创建租约", { client.requests.count == 1 })
        try expect(client.requests[0].body.startPage == 9, "初始页码应限制在有效范围")
        await session.stop()?.value
    }

    @MainActor
    private static func offlineRecovery() async throws {
        let client = MockWarmupClient()
        client.isReaderWarmupAvailable = false
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 20_000_000)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        session.pageDidLoad(0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(client.requests.isEmpty, "离线不能发送预热请求")
        client.isReaderWarmupAvailable = true
        try await eventually("网络恢复应建立租约并预热", { client.requests.count >= 2 })
        await session.stop()?.value
        try expect(client.endedIds.count == 1, "恢复后的租约应正常结束")
    }

    @MainActor
    private static func offlineLaunchAuthentication() async throws {
        let client = MockWarmupClient()
        client.readerSessionIdentity = nil
        client.isReaderWarmupAvailable = false
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 10_000_000)
        session.start(comicId: "novel-a", page: 0, totalPages: 20, preheatPages: false, isActive: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(client.requests.isEmpty, "离线启动没有用户信息时不能请求")
        client.readerSessionIdentity = "server-a|user-a"
        client.isReaderWarmupAvailable = true
        try await eventually("首次恢复认证后应创建租约", { !client.requests.isEmpty })
        await session.stop()?.value
        try expect(client.endedIds.count == 1, "首次认证后的租约应正常结束")
    }

    @MainActor
    private static func legacyServer() async throws {
        let client = MockWarmupClient()
        client.response = ReaderWarmupResponse(sessionActive: nil, sessionTtlSeconds: nil)
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 10_000_000)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        session.pageDidLoad(0)
        try await eventually("旧版能力探测后应释放累计锁", { client.endedIds.count == 1 })
        session.setActive(false)
        session.setActive(true)
        try await Task.sleep(nanoseconds: 40_000_000)
        try expect(client.requests.count == 1 && client.endedIds.count == 1, "旧版不能重复加锁或多次释放")
        session.stop()
    }

    @MainActor
    private static func missingEndpoint() async throws {
        let client = MockWarmupClient()
        client.nextError = ReaderWarmupError.unsupportedEndpoint
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 10_000_000)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        try await Task.sleep(nanoseconds: 40_000_000)
        try expect(client.requests.count == 1 && client.endedIds.isEmpty, "缺少接口时应静默停用，不发送释放请求")
        session.stop()
    }

    @MainActor
    private static func lateRequestAndResume() async throws {
        let client = MockWarmupClient()
        client.blockNext = true
        let session = ReaderWarmupSession(client: client)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        session.pageDidLoad(0)
        try await eventually("首个请求应处于处理中", { client.pendingReply != nil })
        let oldId = client.requests[0].body.sessionId
        session.setActive(false)
        session.setActive(true)
        try await eventually("新会话应不被旧请求阻塞", { client.requests.count == 3 })
        try expect(client.endedIds.isEmpty, "不能抢在旧预热请求完成前释放")
        let newId = client.requests[1].body.sessionId
        client.pendingReply?.resume(returning: client.response)
        client.pendingReply = nil
        try await eventually("迟到请求完成后应释放旧会话", { client.endedIds == [oldId] })
        try expect(newId != oldId && !client.endedIds.contains(newId), "旧会话结束不能影响新会话")
        await session.stop()?.value
        try expect(client.endedIds == [oldId, newId], "新会话仍应正常结束")
    }

    @MainActor
    private static func identityChange() async throws {
        let client = MockWarmupClient()
        let session = ReaderWarmupSession(client: client)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: false, isActive: true)
        try await eventually("会话应已建立", { client.requests.count == 1 })
        client.readerSessionIdentity = "server-b|user-b"
        await session.stop()?.value
        session.setActive(true)
        try expect(client.endedIds.isEmpty, "不能向新账号/服务器发送旧租约释放")
        try expect(client.requests.count == 1, "不能将旧会话发给新账号/服务器")
    }

    @MainActor
    private static func retryPrefetch() async throws {
        let client = MockWarmupClient()
        let session = ReaderWarmupSession(client: client)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        session.pageDidLoad(0)
        try await eventually("应建立预热会话", { client.requests.count == 2 })
        client.nextError = URLError(.timedOut)
        session.updatePage(4, totalPages: 20)
        session.pageDidLoad(4)
        try await eventually("预热应发出并失败", { client.requests.count == 3 })
        session.updatePage(5, totalPages: 20)
        session.pageDidLoad(5)
        try await eventually("预热失败后同一段应可重试", { client.requests.count == 4 })
        try expect(client.requests[3].body.startPage == 6, "重试应使用当前页")
        await session.stop()?.value
    }

    @MainActor
    private static func uncertainProbe() async throws {
        let client = MockWarmupClient()
        client.nextError = URLError(.networkConnectionLost)
        let session = ReaderWarmupSession(client: client, heartbeatNanoseconds: 10_000_000)
        session.start(comicId: "comic-a", page: 0, totalPages: 20, preheatPages: true, isActive: true)
        try await eventually("探测结果不确定时应尝试释放", { client.endedIds.count == 1 })
        try await Task.sleep(nanoseconds: 40_000_000)
        try expect(client.requests.count == 1, "探测失败后不能反复调用旧版累计锁接口")
        session.stop()
    }
}
