import SwiftUI
import AppKit
import Darwin

@main
struct SilverApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(CinemaAppDelegate.self) private var appDelegate

    init() {
        StartupDisplayGuard.arm()
        SilverLog.info("Silver starting executable=\(ProcessInfo.processInfo.arguments.first ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString) log=\(SilverLog.fileURL.path)")
    }

    var body: some Scene {
        WindowGroup("Silver") {
            CinemaView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class CinemaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var displayGrabAttempts = 0
    private var hasEstablishedDisplayGrab = false
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first, window.screen != nil else {
                self.failDisplayGrab("no window is attached to a display")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
            NSCursor.hide()
            self.verifyDisplayGrab()
        }
    }

    private func verifyDisplayGrab() {
        displayGrabAttempts += 1
        if let window = NSApp.windows.first,
           window.screen != nil,
           window.isVisible,
           window.isKeyWindow,
           window.styleMask.contains(.fullScreen),
           NSRunningApplication.current.isActive {
            hasEstablishedDisplayGrab = true
            SilverLog.info("Exclusive full-screen display grab established screen=\(window.screen?.localizedName ?? "unknown")")
            StartupDisplayGuard.markGrabbed()
            return
        }
        guard displayGrabAttempts < 20 else {
            failDisplayGrab("the full-screen window did not become active and visible")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.verifyDisplayGrab()
        }
    }

    private func failDisplayGrab(_ reason: String) {
        guard !isTerminating else { return }
        isTerminating = true
        SilverLog.error("Cannot grab display: \(reason); terminating")
        NSCursor.unhide()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        NSCursor.unhide()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if hasEstablishedDisplayGrab && !isTerminating {
            failDisplayGrab("another application took control of the cinema display")
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if hasEstablishedDisplayGrab && !isTerminating {
            failDisplayGrab("the cinema window left full screen")
        }
    }

    func prepareDynamicRange(hdr: Bool) {
        guard let window = NSApp.windows.first else { return }
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.preferredDynamicRange = hdr ? .high : .standard
    }

    func verifyDisplayGrabAfterModeChange() async -> Bool {
        guard let window = NSApp.windows.first else {
            failDisplayGrab("the cinema window disappeared during the mode change")
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 {
            if window.screen != nil, window.isVisible, window.isKeyWindow,
               window.styleMask.contains(.fullScreen), NSRunningApplication.current.isActive {
                SilverLog.info("Exclusive full-screen display grab verified after mode change")
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        failDisplayGrab("full screen was lost during the display mode change")
        return false
    }
}

private enum StartupDisplayGuard {
    private static let lock = NSLock()
    private static var grabbed = false

    static func arm() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 7) {
            lock.lock()
            let succeeded = grabbed
            lock.unlock()
            guard !succeeded else { return }
            SilverLog.error("macOS did not establish an active full-screen UI session; terminating")
            Darwin.exit(70)
        }
    }

    static func markGrabbed() {
        lock.lock()
        grabbed = true
        lock.unlock()
    }
}
