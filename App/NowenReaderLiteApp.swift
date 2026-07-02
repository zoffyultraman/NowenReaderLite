import SwiftUI
import SwiftData

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == "com.nowen.readerlite.background" {
            // 将 completionHandler 交给 DownloadManager
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}

@main
struct NowenReaderLiteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            RootRouter()
                .environment(APIClient.shared)
                .preferredColorScheme(.none)
        }
        .modelContainer(for: [CachedComic.self, ServerRecord.self, SavedAccount.self, DownloadedComicRecord.self])
    }
}
