import SwiftUI
import SwiftData

@main
struct NowenReaderLiteApp: App {
    var body: some Scene {
        WindowGroup {
            RootRouter()
                .environment(APIClient.shared)
                .preferredColorScheme(.none)
        }
        .modelContainer(for: [CachedComic.self, ServerRecord.self, SavedAccount.self, DownloadedComicRecord.self])
    }
}
