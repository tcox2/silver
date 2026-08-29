import SwiftUI
import AppKit

@main
struct SilverApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(CinemaAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Silver") {
            CinemaView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class CinemaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        DispatchQueue.main.async {
            NSApp.windows.first?.toggleFullScreen(nil)
            NSCursor.hide()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSCursor.unhide()
    }
}
