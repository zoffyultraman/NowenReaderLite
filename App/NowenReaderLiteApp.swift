import SwiftUI
import SwiftData

@main
struct NowenReaderLiteApp: App {
    var body: some Scene {
        WindowGroup {
            RootRouter()
                .preferredColorScheme(.none)
        }
        .modelContainer(for: [CachedComic.self, ServerRecord.self, SavedAccount.self, DownloadedComicRecord.self])
    }
}
