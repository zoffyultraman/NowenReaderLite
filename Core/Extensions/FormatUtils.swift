import Foundation

/// 格式化文件大小
func formatFileSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
}

/// Comparable 扩展
extension Comparable {
    func clamped(to range: ClosedRange<Self>, default defaultValue: Self) -> Self {
        range.contains(self) ? self : defaultValue
    }
}

/// Array 安全下标
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
