import Foundation
import Combine
import RuuviCore
import RuuviMQTT

/// Owns Home Assistant settings, the ownership ledger, the Keychain password and the publisher lifecycle.
/// Main queue only. Keychain work runs on `keychainQueue`.
final class HomeAssistantBridge: ObservableObject {
    @Published private(set) var status = "Home Assistant publishing is off"
    @Published private(set) var enabled: Bool
    @Published private(set) var settings: HomeAssistantSettings
    @Published private(set) var ledger: HomeAssistantLedger
    @Published private(set) var hasPassword: Bool
    @Published private(set) var keychainProblem = false
    @Published private(set) var connected = false
    @Published private(set) var saving = false
    /// Tags whose removal the broker acknowledged during this session.
    @Published private(set) var removed: Set<String> = []
    let bridgeID: String
    private let defaults: UserDefaults
    private let keychain = KeychainPasswordStore()
    private let keychainQueue = DispatchQueue(label: "org.ruuvimac.keychain")
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private var publisher: HomeAssistantPublisher?
    private var stopping: HomeAssistantPublisher?
    private var router = HomeAssistantRouter()
    /// Latest name of every MAC-identified tag heard over Bluetooth this session, for birth and rename republish.
    private var names: [String: String] = [:]
    private var generation = 0
    /// Set by `shutdown` (quit). Nothing restarts publishing afterwards.
    private var isShutDown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "ha.settings").flatMap { try? JSONDecoder().decode(HomeAssistantSettings.self, from: $0) }
            ?? HomeAssistantSettings(host: "homeassistant.local")
        ledger = defaults.data(forKey: "ha.ledger").flatMap { try? JSONDecoder().decode(HomeAssistantLedger.self, from: $0) }
            ?? HomeAssistantLedger()
        enabled = defaults.bool(forKey: "ha.enabled")
        hasPassword = defaults.bool(forKey: "ha.hasPassword")
        if let saved = defaults.string(forKey: "ha.bridgeID") { bridgeID = saved }
        else { bridgeID = HomeAssistantDiscovery.newBridgeID(); defaults.set(bridgeID, forKey: "ha.bridgeID") }
    }

    private static func describe(_ error: Error) -> String {
        (error as? KeychainError)?.message ?? error.localizedDescription
    }

    // MARK: Lifecycle

    /// Starts publishing with the current settings if enabled and no publisher is running or stopping.
    func start() {
        guard !isShutDown, publisher == nil, stopping == nil else { return }
        generation += 1
        let current = generation, config = settings
        keychainProblem = false
        guard enabled else { status = "Home Assistant publishing is off"; return }
        if let problem = config.validationError { status = problem; return }
        // ha.hasPassword false means username-only or anonymous; the Keychain is not read.
        guard !config.username.isEmpty, hasPassword else { connect(config, password: nil); return }
        status = "Reading the broker password from the Keychain…"
        let store = keychain
        keychainQueue.async {
            let result = Result { try store.read(account: config.account) }
            DispatchQueue.main.async {
                guard current == self.generation, self.publisher == nil, self.stopping == nil else { return }
                switch result {
                case .success(let password): self.connect(config, password: password)
                case .failure(let error):
                    self.keychainProblem = true
                    self.status = "Password unavailable from Keychain: " + Self.describe(error)
                }
            }
        }
    }

    func retryKeychain() { generation += 1; start() }

    private func connect(_ config: HomeAssistantSettings, password: String?) {
        let p = HomeAssistantPublisher(settings: config, password: password, bridge: bridgeID, version: version)
        p.onStatus = { [weak self, weak p] text in
            guard let self, let p, self.publisher === p else { return }
            self.status = text
        }
        p.onConnected = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.connected = true
            self.router.throttle.resetAll()
            let count = self.ledger.published[config.brokerKey]?.count ?? 0
            self.status = "Connected to the Home Assistant broker · \(count) tags published"
            for removal in self.ledger.pendingRemovals(for: config) { p.remove(removal) }
        }
        p.onDisconnected = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.connected = false
        }
        p.onBirth = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.router.throttle.resetAll()
            for (key, name) in self.names where self.ledger.isPublishing(key, publishNewTags: config.publishNewTags) {
                p.publishConfig(tag: .init(macKey: key, name: name))
            }
        }
        p.onRemoved = { [weak self] removal in
            guard let self else { return }
            var next = self.ledger
            next.completeRemoval(removal)
            self.ledger = next; self.saveLedger()
            self.removed.insert(removal.macKey)
        }
        publisher = p
        p.start()
    }

    /// Stops the running publisher, if any, and starts again with the current settings once it has stopped.
    private func restart() {
        generation += 1
        connected = false
        guard let old = publisher else { start(); return }
        publisher = nil
        stopping = old
        old.stop { [weak self] in
            guard let self else { return }
            if self.stopping === old { self.stopping = nil }
            self.start()   // no-op after shutdown
        }
    }

    /// Quit path, terminal: no later save, Keychain read or stop continuation restarts publishing.
    /// Completion runs on the main run loop, never synchronously, once the running publisher has closed.
    /// The app delegate adds the hard 2 second bound.
    func shutdown(_ completion: @escaping () -> Void) {
        isShutDown = true
        generation += 1
        connected = false
        guard let p = publisher else { MainRunLoop.perform(completion); return }
        publisher = nil
        p.stop(closed: completion)
    }

    // MARK: Settings

    /// Validates, stores the password first, then commits the settings and restarts.
    /// Completion receives an error message, or nil once the new settings are active. Old settings stay on failure.
    func apply(settings new: HomeAssistantSettings, enabled newEnabled: Bool, password: String, clearPassword: Bool,
               completion: @escaping (String?) -> Void) {
        guard !saving else { completion("Still saving the previous change."); return }
        if newEnabled, let problem = new.validationError { completion(problem); return }
        let oldAccount = settings.account
        let hadPassword = hasPassword
        let accountChanged = new.account != oldAccount
        let noPassword = new.username.isEmpty || clearPassword
        if !noPassword, password.isEmpty, hadPassword, accountChanged {
            completion("Enter the password again for the new username, host or port."); return
        }
        let commit: (Bool?) -> Void = { [weak self] passwordStored in
            guard let self, !self.isShutDown else { return }
            self.settings = new; self.enabled = newEnabled
            if let stored = passwordStored { self.hasPassword = stored; self.defaults.set(stored, forKey: "ha.hasPassword") }
            self.defaults.set(try? JSONEncoder().encode(new), forKey: "ha.settings")
            self.defaults.set(newEnabled, forKey: "ha.enabled")
            self.restart()
            completion(nil)
        }
        let store = keychain
        if noPassword {
            guard hadPassword else { commit(false); return }
            saving = true
            keychainQueue.async {
                let result = Result { try store.delete(account: oldAccount) }
                DispatchQueue.main.async {
                    self.saving = false
                    switch result {
                    case .success: commit(false)
                    case .failure(let error): completion("Could not remove the saved password: " + Self.describe(error))
                    }
                }
            }
        } else if !password.isEmpty {
            saving = true
            let account = new.account
            keychainQueue.async {
                let result = Result { try store.save(password, account: account) }
                if case .success = result, hadPassword, account != oldAccount { try? store.delete(account: oldAccount) }
                DispatchQueue.main.async {
                    self.saving = false
                    switch result {
                    case .success: commit(true)
                    case .failure(let error): completion("Could not save the password in the Keychain: " + Self.describe(error))
                    }
                }
            }
        } else {
            commit(nil)
        }
    }

    // MARK: Readings

    func receive(sensor: Sensor, reading: Reading, rssi: Int, source: ReadingSource) {
        guard source == .bluetooth, let key = HomeAssistantDiscovery.macKey(sensor.id) else { return }
        names[key] = sensor.name
        var next = ledger
        // Record the publish choice on first sighting while publishing is enabled, even before the
        // publisher is connected (Keychain prompt, replacement), so a later default change cannot flip it.
        if enabled { next.adopt(key, publishNewTags: settings.publishNewTags) }
        guard let p = publisher else {
            if next != ledger { ledger = next; saveLedger() }
            return
        }
        if let routed = router.route(id: sensor.id, source: source, connected: p.connected, ledger: &next,
                                     publishNewTags: p.settings.publishNewTags, now: Date()) {
            p.publish(tag: .init(macKey: routed, name: sensor.name), reading: reading, rssi: rssi)
            if next.markPublished(routed, brokerKey: p.settings.brokerKey) {
                status = "Connected to the Home Assistant broker · \(next.published[p.settings.brokerKey]?.count ?? 0) tags published"
            }
        }
        // Assign only on change: this runs for every advertisement and `ledger` is published.
        if next != ledger { ledger = next; saveLedger() }
    }

    func renamed(_ sensor: Sensor) {
        guard let key = HomeAssistantDiscovery.macKey(sensor.id) else { return }
        names[key] = sensor.name
        guard let p = publisher, ledger.isPublishing(key, publishNewTags: p.settings.publishNewTags),
              ledger.published[p.settings.brokerKey]?.contains(key) == true else { return }
        p.publishConfig(tag: .init(macKey: key, name: sensor.name))
    }

    // MARK: Per-tag controls

    func macKey(for id: String) -> String? { HomeAssistantDiscovery.macKey(id) }
    func isPublishing(_ id: String) -> Bool {
        macKey(for: id).map { ledger.isPublishing($0, publishNewTags: settings.publishNewTags) } ?? false
    }
    func isRemovalPending(_ id: String) -> Bool { macKey(for: id).map(ledger.isRemovalPending) ?? false }
    func wasRemoved(_ id: String) -> Bool { macKey(for: id).map(removed.contains) ?? false }

    func setPublishing(_ id: String, _ on: Bool) {
        guard let key = macKey(for: id), !ledger.isRemovalPending(key) else { return }
        var next = ledger
        next.setPublishing(key, on)
        ledger = next; saveLedger()
        if on { router.throttle.reset(key); removed.remove(key) }
    }

    func remove(_ id: String) {
        guard let key = macKey(for: id) else { return }
        var next = ledger
        let removal = next.queueRemoval(key, settings: publisher?.settings ?? settings)
        ledger = next; saveLedger()
        removed.remove(key)
        publisher?.remove(removal)
    }

    func removeAll() {
        var next = ledger
        let removals = next.queueRemoveAll(settings: publisher?.settings ?? settings)
        ledger = next; saveLedger()
        for removal in removals { removed.remove(removal.macKey); publisher?.remove(removal) }
    }

    private func saveLedger() { defaults.set(try? JSONEncoder().encode(ledger), forKey: "ha.ledger") }
}
