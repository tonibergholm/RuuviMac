import Foundation
import AppKit
import ServiceManagement

final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?
    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        let isEnabled = status == .enabled
        let isPending = status == .requiresApproval
        if enabled != isEnabled { enabled = isEnabled }
        if needsApproval != isPending { needsApproval = isPending }
        if isEnabled, message != nil { message = nil }
    }
    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Open at login: \(error.localizedDescription)"
        }
        refresh()
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
