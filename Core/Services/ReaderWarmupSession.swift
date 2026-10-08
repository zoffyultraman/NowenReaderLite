import Foundation

struct ReaderWarmupResponse: Decodable, Sendable {
    let sessionActive: Bool?
    let sessionTtlSeconds: Int?
}

struct ReaderWarmupBody: Encodable, Sendable {
    let sessionId: String
    let startPage: Int
    let count: Int
}

struct ReaderWarmupEndBody: Encodable, Sendable {
    let sessionId: String
}

enum ReaderWarmupError: Error {
    case unsupportedEndpoint
}

@MainActor
protocol ReaderWarmupClient: AnyObject {
    var readerServerIdentity: String { get }
    var readerSessionIdentity: String? { get }
    var isReaderWarmupAvailable: Bool { get }
    func warmupReaderPages(comicId: String, body: ReaderWarmupBody) async throws -> ReaderWarmupResponse
    func endReaderWarmup(comicId: String, sessionId: String) async throws
}

/// 服务端预热租约独立于阅读统计会话；暂停后恢复必须使用新的 ID。
@MainActor
final class ReaderWarmupSession {
    private final class Lease {
        let id = "ios-reader-\(UUID().uuidString)"
        let identity: String
        let comicId: String
        var closed = false
        var attempted = false
        var released = false
        var supported = false
        var prefetchBucket: Int?
        var requestTask: Task<Void, Never>?

        init(identity: String, comicId: String) {
            self.identity = identity
            self.comicId = comicId
        }
    }

    private let client: any ReaderWarmupClient
    private let heartbeatNanoseconds: UInt64
    private var identity: String?
    private var serverIdentity = ""
    private var comicId = ""
    private var page = 0
    private var totalPages = 0
    private var preheatPages = false
    private var hasLoadedPage = false
    private var started = false
    private var active = false
    private var lease: Lease?
    private var heartbeatTask: Task<Void, Never>?
    private var unsupportedIdentities = Set<String>()

    init(client: any ReaderWarmupClient, heartbeatNanoseconds: UInt64 = 30_000_000_000) {
        self.client = client
        self.heartbeatNanoseconds = heartbeatNanoseconds
    }

    func start(comicId: String, page: Int, totalPages: Int, preheatPages: Bool, isActive: Bool) {
        guard !started, !comicId.isEmpty, totalPages > 0 else { return }
        started = true
        identity = client.readerSessionIdentity
        serverIdentity = client.readerServerIdentity
        self.comicId = comicId
        self.totalPages = totalPages
        self.page = min(max(page, 0), totalPages - 1)
        self.preheatPages = preheatPages
        hasLoadedPage = false
        active = isActive
        if active { beginLease() }
    }

    func updatePage(_ page: Int, totalPages: Int) {
        guard started else { return }
        if totalPages > 0 { self.totalPages = totalPages }
        let safePage = min(max(page, 0), self.totalPages - 1)
        if self.page != safePage { hasLoadedPage = false }
        self.page = safePage
        if let lease { prefetch(lease) }
    }

    func pageDidLoad(_ page: Int) {
        guard started, page == self.page else { return }
        hasLoadedPage = true
        if let lease { prefetch(lease) }
    }

    func setActive(_ active: Bool) {
        guard started, self.active != active else { return }
        self.active = active
        if active {
            beginLease()
        } else {
            closeLease()
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        started = false
        active = false
        return closeLease()
    }

    private func beginLease() {
        guard started, active, lease == nil,
              serverIdentity == client.readerServerIdentity else { return }
        if identity == nil { identity = client.readerSessionIdentity }
        if let identity, unsupportedIdentities.contains(identity) { return }

        if heartbeatTask == nil {
            heartbeatTask = Task { [weak self, heartbeatNanoseconds] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: heartbeatNanoseconds)
                    } catch { return }
                    self?.heartbeat()
                }
            }
        }

        // 离线启动时可能还没有用户信息；认证恢复后由心跳创建首个租约。
        guard let identity, identity == client.readerSessionIdentity else { return }
        let lease = Lease(identity: identity, comicId: comicId)
        self.lease = lease
        renew(lease)
        prefetch(lease)
    }

    private func heartbeat() {
        guard serverIdentity == client.readerServerIdentity else {
            closeLease()
            return
        }
        guard client.isReaderWarmupAvailable else { return }
        if let identity, identity != client.readerSessionIdentity {
            closeLease()
            return
        }
        guard let lease else {
            beginLease()
            return
        }
        renew(lease)
        prefetch(lease)
    }

    private func renew(_ lease: Lease) {
        enqueue(lease, startPage: page, count: -1, bucket: nil)
    }

    private func prefetch(_ lease: Lease) {
        guard preheatPages, hasLoadedPage, page + 1 < totalPages else { return }
        let bucket = page / 4
        guard lease.prefetchBucket != bucket else { return }
        lease.prefetchBucket = bucket
        enqueue(lease, startPage: page + 1, count: min(8, totalPages - page - 1), bucket: bucket)
    }

    private func enqueue(_ lease: Lease, startPage: Int, count: Int, bucket: Int?) {
        let previous = lease.requestTask
        // 串行发送，结束请求等待已发出的预热完成，防止迟到请求重新加锁。
        lease.requestTask = Task { [self] in
            await previous?.value
            guard !lease.closed, lease.identity == client.readerSessionIdentity,
                  client.isReaderWarmupAvailable, count == -1 || (lease.supported && hasLoadedPage),
                  bucket == nil || bucket == page / 4 else {
                if let bucket, lease.prefetchBucket == bucket { lease.prefetchBucket = nil }
                return
            }
            lease.attempted = true
            do {
                let response = try await client.warmupReaderPages(
                    comicId: lease.comicId,
                    body: ReaderWarmupBody(sessionId: lease.id, startPage: startPage, count: count)
                )
                guard response.sessionActive != nil, response.sessionTtlSeconds != nil else {
                    // 旧服务端每次 warmup 都累加锁；探测一次后配对释放，停用心跳。
                    unsupportedIdentities.insert(lease.identity)
                    if self.lease === lease { closeLease() }
                    return
                }
                lease.supported = true
                if response.sessionActive == false, self.lease === lease {
                    closeLease()
                    if active { beginLease() }
                }
            } catch ReaderWarmupError.unsupportedEndpoint {
                lease.attempted = false
                unsupportedIdentities.insert(lease.identity)
                if self.lease === lease { closeLease() }
            } catch {
                if let bucket, lease.prefetchBucket == bucket { lease.prefetchBucket = nil }
                if !lease.supported {
                    // 探测结果不确定时也不重复加锁；下次进入阅读器可重新探测。
                    unsupportedIdentities.insert(lease.identity)
                    if self.lease === lease { closeLease() }
                }
            }
        }
    }

    @discardableResult
    private func closeLease() -> Task<Void, Never>? {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard let lease else { return nil }
        self.lease = nil
        lease.closed = true
        let previous = lease.requestTask
        return Task { [client] in
            await previous?.value
            guard lease.attempted, !lease.released,
                  lease.identity == client.readerSessionIdentity,
                  client.isReaderWarmupAvailable else { return }
            lease.released = true
            try? await client.endReaderWarmup(comicId: lease.comicId, sessionId: lease.id)
        }
    }

    deinit {
        heartbeatTask?.cancel()
    }
}
