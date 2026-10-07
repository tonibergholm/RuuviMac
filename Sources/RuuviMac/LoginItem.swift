import Foundation
import AppKit
import ServiceManagement
import RuuviCore

final class LoginItem: ObservableObject {
    @Published private(set) var state = LoginItemState()
    var registered: Bool { state.registered }
    var needsApproval: Bool { state.needsApproval }
    var message: String? { state.message }
    init() { refresh() }
    func refresh() {
        var next = state
        observeStatus(into: &next)
        if next != state { state = next }
    }
    func set(_ on: Bool) {
        var next = state
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            next.succeeded()
        } catch {
            next.failed("Open at login: \(error.localizedDescription)")
        }
        observeStatus(into: &next)
        if next != state { state = next }
    }
    private func observeStatus(into next: inout LoginItemState) {
        let status = SMAppService.mainApp.status
        next.observe(registered: status == .enabled || status == .requiresApproval,
                     needsApproval: status == .requiresApproval)
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchReason {
    /// True when macOS opened the app as a login item. Read in applicationDidFinishLaunching.
    static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
