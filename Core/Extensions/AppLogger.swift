import Foundation

/// 统一日志工具，release 构建自动静默（使用 NSLog 替代 os.Logger 以避免隐私标注兼容性问题）
enum AppLogger {
    static func log(_ message: String) {
        #if DEBUG
        NSLog("[NowenReader] %@", message)
        #endif
    }

    static func error(_ message: String) {
        #if DEBUG
        NSLog("[NowenReader ERROR] %@", message)
        #endif
    }
}
