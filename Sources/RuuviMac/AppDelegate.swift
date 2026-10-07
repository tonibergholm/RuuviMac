import AppKit
import SwiftUI

final class SelectionModel: ObservableObject {
    @Published var selected: String?
}

/// Owns objects that must outlive the main window, and switches the Dock icon with it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SensorStore()
    let selection = SelectionModel()
    let loginItem = LoginItem()
    private var activeObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private weak var mainWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    /// Set before or after the main window appears; whichever comes second hides it.
    var startHidden = false { didSet { hideIfNeeded() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keeps timers and scan delivery on time while windowless. Idle sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Collecting RuuviTag readings")
        if LaunchReason.isLoginItemLaunch() { startHidden = true }
        // Returning from System Settings → Login Items should show the new state.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.loginItem.refresh()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The Home Assistant publisher adds its bounded offline message here later.
        .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        store.persist()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    func registerMainWindow(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        mainWindow = window
        windowObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                NSApp.setActivationPolicy(.regular)
            }
        ]
        hideIfNeeded()
    }
    private func hideIfNeeded() {
        guard startHidden, let mainWindow else { return }
        startHidden = false
        mainWindow.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
    /// Called before `openWindow(id: "main")` so the Dock icon is back when the window appears.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
