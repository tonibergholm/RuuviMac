/// Toggle state for open at login. Registered includes "awaiting approval", so the user can still turn it off.
public struct LoginItemState: Equatable {
    public private(set) var registered = false
    public private(set) var needsApproval = false
    public private(set) var message: String?
    public init() {}
    /// Applies a status read. Clears the message only when registration or approval actually changed.
    public mutating func observe(registered: Bool, needsApproval: Bool) {
        let changed = registered != self.registered || needsApproval != self.needsApproval
        self.registered = registered
        self.needsApproval = needsApproval
        if changed { message = nil }
    }
    public mutating func succeeded() { message = nil }
    public mutating func failed(_ text: String) { message = text }
}
