import Foundation

/// Schedules work on the main run loop in common and modal-panel modes. AppKit runs the modal-panel mode while
/// it waits for `.terminateLater`, so quit-time completions must not rely on plain main-queue dispatch.
public enum MainRunLoop {
    private static let modes = [CFRunLoopMode.commonModes.rawValue, "NSModalPanelRunLoopMode" as CFString] as CFArray
    /// Safe to call from any thread.
    public static func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    /// Call on the main thread. Returns the timer so callers can cancel it.
    @discardableResult public static func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        return timer
    }
}
