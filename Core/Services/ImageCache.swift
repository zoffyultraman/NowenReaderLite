import UIKit
import CommonCrypto

/// 二级图片缓存：NSCache（内存）+ FileManager（磁盘）
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dataMemory = NSCache<NSString, NSData>()
    private let diskDir: URL
    private let fileManager = FileManager.default
    private let diskReadQueue = DispatchQueue(
        label: "com.nowen.readerlite.image-cache.read",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let diskWriteQueue = DispatchQueue(
        label: "com.nowen.readerlite.image-cache.write",
        qos: .utility
    )
    private let generationLock = NSLock()
    private var generation = 0
    private var writeCountSincePrune = 0
    private let maxDiskCacheBytes: Int64 = 300 * 1024 * 1024

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 100 * 1024 * 1024 // 100MB
        dataMemory.countLimit = 80
        dataMemory.totalCostLimit = 80 * 1024 * 1024

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        diskWriteQueue.async { [fileManager, diskDir] in
            try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Public

    func memoryImage(forKey key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func image(forKey key: String) async -> UIImage? {
        let nsKey = key as NSString

        // L1: 内存
        if let cached = memory.object(forKey: nsKey) {
            return cached
        }

        // L2: 磁盘
        let loadGeneration = currentGeneration()
        let fileURL = diskPath(for: key)
        let diskImage: UIImage? = await withCheckedContinuation { continuation in
            diskReadQueue.async {
                guard let data = try? Data(contentsOf: fileURL),
                      let decoded = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded.preparingForDisplay() ?? decoded)
            }
        }
        guard let image = diskImage else {
            return nil
        }
        guard loadGeneration == currentGeneration() else { return nil }

        // 回填内存（附带真实像素字节成本）
        setMemoryOnly(image, forKey: key)
        return image
    }

    /// 读取原始图片数据，供需要保留透明度和原始尺寸的 EPUB 插图使用。
    func data(forKey key: String) async -> Data? {
        let nsKey = key as NSString
        if let cached = dataMemory.object(forKey: nsKey) {
            return cached as Data
        }
        let fileURL = diskPath(for: key)
        let loadGeneration = currentGeneration()
        let data: Data? = await withCheckedContinuation { continuation in
            diskReadQueue.async {
                continuation.resume(returning: try? Data(contentsOf: fileURL))
            }
        }
        guard loadGeneration == currentGeneration() else { return nil }
        if let data {
            dataMemory.setObject(
                data as NSData,
                forKey: nsKey,
                cost: data.count
            )
        }
        return data
    }

    func setMemoryOnly(_ image: UIImage, forKey key: String) {
        let cost = Self.decodedCost(of: image)
        guard cost <= memory.totalCostLimit else { return }
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    static func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(
                by: cgImage.height
            )
            return overflow ? Int.max : max(1, cost)
        }
        let cost = Double(image.size.width * image.scale)
            * Double(image.size.height * image.scale) * 4
        guard cost.isFinite, cost < Double(Int.max) else { return Int.max }
        return max(1, Int(cost))
    }

    func set(_ image: UIImage, forKey key: String) {
        set(image, originalData: nil, forKey: key)
    }

    func set(_ image: UIImage, originalData: Data?, forKey key: String) {
        let writeGeneration = currentGeneration()

        // 写内存（附带字节成本）
        setMemoryOnly(image, forKey: key)

        // 异步写磁盘（优先直写原字节，避免无谓 JPEG 重编码）
        let fileURL = diskPath(for: key)
        diskWriteQueue.async {
            guard writeGeneration == self.currentGeneration() else { return }
            guard let data = originalData ?? image.jpegData(compressionQuality: 0.85) else { return }
            self.writeDiskDataUnlocked(data, to: fileURL)
        }
    }

    /// 保存原始图片数据；常规缩略图仍可继续使用 JPEG 压缩路径。
    func setData(_ data: Data, forKey key: String) {
        let nsKey = key as NSString
        let writeGeneration = currentGeneration()
        dataMemory.setObject(data as NSData, forKey: nsKey, cost: data.count)
        let fileURL = diskPath(for: key)
        diskWriteQueue.async {
            guard writeGeneration == self.currentGeneration() else { return }
            self.writeDiskDataUnlocked(data, to: fileURL)
        }
    }

    func clear() async {
        advanceGeneration()
        memory.removeAllObjects()
        dataMemory.removeAllObjects()
        await withCheckedContinuation { continuation in
            diskWriteQueue.async {
                try? self.fileManager.removeItem(at: self.diskDir)
                try? self.fileManager.createDirectory(
                    at: self.diskDir,
                    withIntermediateDirectories: true
                )
                self.writeCountSincePrune = 0
                continuation.resume()
            }
        }
    }

    /// 磁盘缓存大小（字节）
    func diskSize() async -> Int64 {
        await withCheckedContinuation { continuation in
            diskReadQueue.async {
                guard let items = try? self.fileManager.contentsOfDirectory(
                    at: self.diskDir,
                    includingPropertiesForKeys: [.fileSizeKey]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }
                let total = items.reduce(Int64(0)) { result, url in
                    let size = (try? url.resourceValues(
                        forKeys: [.fileSizeKey]
                    ))?.fileSize ?? 0
                    return result + Int64(size)
                }
                continuation.resume(returning: total)
            }
        }
    }

    // MARK: - Private

    private func writeDiskDataUnlocked(_ data: Data, to fileURL: URL) {
        if !fileManager.fileExists(atPath: diskDir.path) {
            try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: .atomic)
        writeCountSincePrune += 1
        if writeCountSincePrune >= 50 {
            writeCountSincePrune = 0
            pruneDiskCacheIfNeededUnlocked()
        }
    }

    private func pruneDiskCacheIfNeededUnlocked() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: diskDir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        var entries: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var totalBytes: Int64 = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            totalBytes += size
            entries.append((url, size, modified))
        }
        guard totalBytes > maxDiskCacheBytes else { return }

        let targetBytes = maxDiskCacheBytes * 4 / 5
        entries.sort { $0.modifiedAt < $1.modifiedAt }
        for entry in entries {
            guard totalBytes > targetBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private func diskPath(for key: String) -> URL {
        let filename = key.sha256hex
        return diskDir.appendingPathComponent(filename)
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func advanceGeneration() {
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }
}

extension ImageCache: @unchecked Sendable {}

// MARK: - String SHA256

private let sha256HexTable: [Character] = Array("0123456789abcdef")

private extension String {
    var sha256hex: String {
        guard let data = self.data(using: .utf8) else { return self }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        var chars: [Character] = []
        chars.reserveCapacity(64)
        for byte in hash {
            chars.append(sha256HexTable[Int(byte >> 4)])
            chars.append(sha256HexTable[Int(byte & 0x0f)])
        }
        return String(chars)
    }
}
