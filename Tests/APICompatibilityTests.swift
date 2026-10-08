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
        print("PASS: 13 API compatibility and reader lifecycle scenarios")
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
