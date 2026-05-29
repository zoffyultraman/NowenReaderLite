import SwiftUI
import SwiftData

@main
struct NowenReaderLiteApp: App {
    var body: some Scene {
        WindowGroup {
            RootRouter()
                .preferredColorScheme(.none) // 跟随系统
        }
        .modelContainer(for: [CachedComic.self, ServerRecord.self, SavedAccount.self])
    }
}
