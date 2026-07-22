import UIKit
import CommonCrypto

/// 二级图片缓存：NSCache（内存）+ FileManager（磁盘）
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let fileManager = FileManager.default

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 100 * 1024 * 1024 // 100MB

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: - Public

    func get(_ key: String) -> UIImage? {
        let nsKey = key as NSString

        // L1: 内存
        if let cached = memory.object(forKey: nsKey) {
            return cached
        }

        // L2: 磁盘
        let fileURL = diskPath(for: key)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        // 回填内存
        memory.setObject(image, forKey: nsKey)
        return image
    }

    func set(_ image: UIImage, forKey key: String) {
        let nsKey = key as NSString

        // 写内存
        memory.setObject(image, forKey: nsKey)

        // 异步写磁盘
        let fileURL = diskPath(for: key)
        let data = image.jpegData(compressionQuality: 0.85)
        Task.detached(priority: .utility) {
            try? data?.write(to: fileURL)
        }
    }

    func clear() {
        memory.removeAllObjects()
        try? fileManager.removeItem(at: diskDir)
        try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 磁盘缓存大小（字节）
    var diskSize: Int64 {
        guard let items = try? fileManager.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Private

    private func diskPath(for key: String) -> URL {
        let filename = key.sha256hex
        return diskDir.appendingPathComponent(filename)
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
