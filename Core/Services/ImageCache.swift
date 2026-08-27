import UIKit
import CommonCrypto

/// 二级图片缓存：NSCache（内存）+ FileManager（磁盘）
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dataMemory = NSCache<NSString, NSData>()
    private let diskDir: URL
    private let fileManager = FileManager.default
    private let diskQueue = DispatchQueue(
        label: "com.nowen.readerlite.image-cache",
        qos: .utility
    )
    private let generationLock = NSLock()
    private var generation = 0

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 100 * 1024 * 1024 // 100MB
        dataMemory.countLimit = 80
        dataMemory.totalCostLimit = 80 * 1024 * 1024

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: - Public

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
            diskQueue.async {
                guard let data = try? Data(contentsOf: fileURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(data: data))
            }
        }
        guard let image = diskImage else {
            return nil
        }
        guard loadGeneration == currentGeneration() else { return nil }

        // 回填内存
        memory.setObject(image, forKey: nsKey)
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
            diskQueue.async {
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

    func set(_ image: UIImage, forKey key: String) {
        let nsKey = key as NSString
        let writeGeneration = currentGeneration()

        // 写内存
        memory.setObject(image, forKey: nsKey)

        // 异步写磁盘
        let fileURL = diskPath(for: key)
        diskQueue.async {
            guard writeGeneration == self.currentGeneration() else { return }
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 保存原始图片数据；常规缩略图仍可继续使用 JPEG 压缩路径。
    func setData(_ data: Data, forKey key: String) {
        let nsKey = key as NSString
        let writeGeneration = currentGeneration()
        dataMemory.setObject(data as NSData, forKey: nsKey, cost: data.count)
        if let image = UIImage(data: data) {
            memory.setObject(image, forKey: nsKey)
        }
        let fileURL = diskPath(for: key)
        diskQueue.async {
            guard writeGeneration == self.currentGeneration() else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() async {
        advanceGeneration()
        memory.removeAllObjects()
        dataMemory.removeAllObjects()
        await withCheckedContinuation { continuation in
            diskQueue.async {
                try? self.fileManager.removeItem(at: self.diskDir)
                try? self.fileManager.createDirectory(
                    at: self.diskDir,
                    withIntermediateDirectories: true
                )
                continuation.resume()
            }
        }
    }

    /// 磁盘缓存大小（字节）
    func diskSize() async -> Int64 {
        await withCheckedContinuation { continuation in
            diskQueue.async {
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

private extension String {
    var sha256hex: String {
        guard let data = self.data(using: .utf8) else { return self }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
