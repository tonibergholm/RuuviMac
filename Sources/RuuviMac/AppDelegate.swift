import AppKit
import SwiftUI
import RuuviMQTT

final class SelectionModel: ObservableObject {
    @Published var selected: String?
    /// Set by the menu to open the Home Assistant sheet in the main window.
    @Published var showHomeAssistant = false
}

/// Owns objects that must outlive the main window, and switches the Dock icon with it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SensorStore()
    let selection = SelectionModel()
    let loginItem = LoginItem()
    let homeAssistant = HomeAssistantBridge()
    private var activeObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private weak var mainWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    /// Set before or after the main window appears; whichever comes second hides it.
    var startHidden = false { didSet { hideIfNeeded() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onReading = { [weak self] sensor, reading, rssi, source in
            self?.homeAssistant.receive(sensor: sensor, reading: reading, rssi: rssi, source: source)
        }
        store.onRename = { [weak self] sensor in self?.homeAssistant.renamed(sensor) }
        homeAssistant.start()
        // Keeps timers and scan delivery on time while windowless. Idle sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Collecting RuuviTag readings")
        if LaunchReason.isLoginItemLaunch() {
            NSApp.setActivationPolicy(.accessory)
            startHidden = true
        }
        // Returning from System Settings → Login Items should show the new state.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.loginItem.refresh()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard homeAssistant.connected else { return .terminateNow }
        // Publish retained offline first. Both paths reply on the main run loop in modal-panel mode,
        // after this method has returned, and never later than 2 seconds.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        homeAssistant.shutdown(reply)
        // Hard bound for quit; scheduled in modal-panel mode so it fires while AppKit waits.
        MainRunLoop.after(2, reply)
        return .terminateLater
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
        if window.isVisible { NSApp.setActivationPolicy(.regular) }
    }
    private func hideIfNeeded() {
        guard startHidden, let mainWindow else { return }
        startHidden = false
        mainWindow.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
    /// Called before `openWindow(id: "main")` so the Dock icon is back when the window appears.
    func showMainWindow() {
        startHidden = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
