# Background collection and menu bar implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RuuviMac keeps collecting when its window is closed, lives in the menu bar, can open at login, and never overwrites an unreadable archive.

**Architecture:** An `NSApplicationDelegate` owns the long-lived objects (`SensorStore`, selection, login item) so they outlive the window. The window becomes a single-instance `Window` scene; a `MenuBarExtra` (menu style) shows tag rows built by a pure, tested helper in `RuuviCore`. Archive safety moves into a tested `GuardedArchive` in `RuuviCore`.

**Tech Stack:** Swift 5.9 tools, SwiftUI + AppKit (macOS 13+), ServiceManagement (`SMAppService`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-07-background-menubar-design.md`

## Global Constraints

- Deployment target stays macOS 13 (`LSMinimumSystemVersion` 13.0, `.macOS(.v13)`). No API newer than macOS 13 without an `if #available` fallback.
- Swift tools 5.9, Swift 5 language mode. No new package dependencies.
- Entitlements unchanged: sandbox, Bluetooth, network client.
- Build and test commands: `swift test --build-system native` and `./scripts/build-app.sh`.
- The app does not prevent idle or system sleep.
- MQTT input passwords stay session-only.
- Prose in README, VALIDATION and commit messages: plain sentences, sentence-case headings, no em dashes.
- All new UI strings in English, matching existing tone ("Open RuuviMac…", "Quit RuuviMac", "Open at login").

## Review Focus

These are not covered by unit tests. Each has a manual check in Task 6.

1. Quit from the menu bar while the window is closed. Expect the last readings saved (archive modification time updates, relaunch shows them).
2. Login launch where detection fails. Expect the window to show normally, with a Dock icon, and collection working. Never a state with no window and no menu bar icon.
3. Reopening the window after closing it. Expect exactly one window, the previous selection still shown, and the Dock icon back.
4. A tag that goes silent while the menu is open or closed. Expect it to turn stale within about 10 seconds of crossing 30 seconds, without any new reading arriving.
5. An unreadable `sensors.json` at launch. Expect the alert, readings still shown in memory, the file byte-for-byte unchanged after quit, and "Move aside and start fresh" working from both the alert and the bottom bar.

---

### Task 1: Guarded archive (no overwrite after failed load)

**Files:**
- Modify: `Sources/RuuviCore/Reading.swift` (add `GuardedArchive` after `SensorArchive`, around line 77)
- Modify: `Sources/RuuviMac/SensorStore.swift:17-27, 105-111`
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (alert in `ContentView`, bottom bar)
- Test: `Tests/RuuviCoreTests/ArchiveGuardTests.swift`

**Interfaces:**
- Consumes: existing `SensorArchive(url:)`, `load() throws -> [Sensor]`, `save(_:) throws`.
- Produces:
  - `public final class GuardedArchive { public init(url: URL); public private(set) var writable: Bool; public func load() -> Result<[Sensor], Error>; @discardableResult public func save(_ sensors: [Sensor]) throws -> Bool; public func moveAside(now: Date) throws -> URL }`
  - `SensorStore.savingPaused: Bool` (`@Published`), `SensorStore.moveArchiveAside()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RuuviCoreTests/ArchiveGuardTests.swift`:

```swift
import XCTest
@testable import RuuviCore

final class ArchiveGuardTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }
    func sensor() -> Sensor {
        Sensor(id: "AA:BB:CC:DD:EE:FF", date: Date(timeIntervalSince1970: 1_000), rssi: -60,
               reading: Reading(date: Date(timeIntervalSince1970: 1_000), temperature: 20))
    }

    func testMissingFileLoadsEmptyAndStaysWritable() throws {
        let archive = GuardedArchive(url: dir.appendingPathComponent("sensors.json"))
        XCTAssertEqual(try archive.load().get().count, 0)
        XCTAssertTrue(archive.writable)
        XCTAssertTrue(try archive.save([sensor()]))
        XCTAssertEqual(try archive.load().get().count, 1)
    }

    func testFailedLoadBlocksSavesAndKeepsOriginalBytes() throws {
        let url = dir.appendingPathComponent("sensors.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        let archive = GuardedArchive(url: url)
        guard case .failure = archive.load() else { return XCTFail("expected load failure") }
        XCTAssertFalse(archive.writable)
        XCTAssertFalse(try archive.save([sensor()]))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testMoveAsideKeepsOldFileAndReenablesSaving() throws {
        let url = dir.appendingPathComponent("sensors.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        let archive = GuardedArchive(url: url)
        _ = archive.load()
        let moved = try archive.moveAside(now: Date(timeIntervalSince1970: 1_791_370_000))
        XCTAssertEqual(moved.lastPathComponent, "sensors.json.unreadable-1791370000")
        XCTAssertEqual(try Data(contentsOf: moved), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(archive.writable)
        XCTAssertTrue(try archive.save([sensor()]))
        XCTAssertEqual(try archive.load().get().first?.id, "AA:BB:CC:DD:EE:FF")
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --build-system native --filter ArchiveGuardTests`
Expected: compile failure, `cannot find 'GuardedArchive' in scope`.

- [ ] **Step 3: Implement `GuardedArchive`**

Append to `Sources/RuuviCore/Reading.swift`:

```swift
/// Refuses to overwrite an archive that failed to load, so unreadable data is never replaced
/// by whatever was collected since launch. `moveAside` keeps the old file and re-enables saving.
public final class GuardedArchive {
    private let archive: SensorArchive
    public private(set) var writable = true
    public init(url: URL) { archive = SensorArchive(url: url) }
    public func load() -> Result<[Sensor], Error> {
        do { let sensors = try archive.load(); writable = true; return .success(sensors) }
        catch { writable = false; return .failure(error) }
    }
    @discardableResult public func save(_ sensors: [Sensor]) throws -> Bool {
        guard writable else { return false }
        try archive.save(sensors); return true
    }
    public func moveAside(now: Date) throws -> URL {
        let target = archive.url.deletingLastPathComponent()
            .appendingPathComponent(archive.url.lastPathComponent + ".unreadable-\(Int(now.timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: archive.url.path) {
            try FileManager.default.moveItem(at: archive.url, to: target)
        }
        writable = true
        return target
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --build-system native --filter ArchiveGuardTests`
Expected: 3 tests pass.

- [ ] **Step 5: Use it in `SensorStore`**

In `Sources/RuuviMac/SensorStore.swift`:

Replace `private let archive: SensorArchive` with `private let archive: GuardedArchive` and add `@Published var savingPaused = false` next to the other published properties.

Replace the `init` body:

```swift
    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        archive = GuardedArchive(url: support.appendingPathComponent("RuuviMac/sensors.json"))
        super.init()
        switch archive.load() {
        case .success(let saved): sensors = saved
        case .failure(let failure):
            savingPaused = true
            error = "Saved data could not be read (\(failure.localizedDescription)). Saving is paused so the file is not overwritten. Choose Move aside and start fresh to keep the old file and save new readings."
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }
```

Replace `persist()` and add `moveArchiveAside()`:

```swift
    func persist() {
        do { try archive.save(sensors) } catch { self.error = "Could not save data: \(error.localizedDescription)" }
    }
    func moveArchiveAside() {
        do {
            let moved = try archive.moveAside(now: Date())
            savingPaused = false; error = nil
            status = "Old data kept as \(moved.lastPathComponent)"
            persist()
        } catch { self.error = "Could not move the saved data aside: \(error.localizedDescription)" }
    }
```

`archive.save` returns `false` while paused, so `persist()` is a silent no-op then. The pause message was already shown at load.

- [ ] **Step 6: Add the UI**

In `ContentView` (`Sources/RuuviMac/RuuviMacApp.swift`), change the alert to offer the action when paused:

```swift
        .alert("Storage problem", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.savingPaused { Button("Move aside and start fresh") { store.moveArchiveAside() } }
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
```

In the bottom bar `HStack`, after `Text(store.status).font(.caption)`, add:

```swift
                if store.savingPaused {
                    Text("Saving paused").font(.caption).foregroundStyle(.orange)
                    Button("Move aside and start fresh") { store.moveArchiveAside() }
                }
```

- [ ] **Step 7: Build and run all tests**

Run: `swift test --build-system native`
Expected: all existing tests plus 3 new pass (the real-broker test is skipped without `RUUVI_MQTT_TEST_PORT`).

- [ ] **Step 8: Commit**

```bash
git add Sources/RuuviCore/Reading.swift Sources/RuuviMac/SensorStore.swift Sources/RuuviMac/RuuviMacApp.swift Tests/RuuviCoreTests/ArchiveGuardTests.swift
git commit -m "Pause saving after an unreadable archive instead of overwriting it"
```

---

### Task 2: Menu row selection helper

**Files:**
- Create: `Sources/RuuviCore/MenuSelection.swift`
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (sidebar sort uses the shared order)
- Test: `Tests/RuuviCoreTests/MenuSelectionTests.swift`

**Interfaces:**
- Consumes: `Sensor` (`id`, `name`, `favorite`, `lastSeen`, `latest`).
- Produces:
  - `public struct MenuRow: Equatable, Identifiable { public let id: String; public let name: String; public let temperature: Double?; public let humidity: Double?; public let stale: Bool }`
  - `public enum MenuSelection { public static let defaultLimit = 8; public static let staleAfter: TimeInterval = 30; public static func sidebarOrder(_ a: Sensor, _ b: Sensor) -> Bool; public static func isStale(_ sensor: Sensor, now: Date) -> Bool; public static func rows(_ sensors: [Sensor], now: Date, limit: Int = defaultLimit) -> (rows: [MenuRow], overflow: Int) }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/RuuviCoreTests/MenuSelectionTests.swift`:

```swift
import XCTest
@testable import RuuviCore

final class MenuSelectionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)
    func sensor(_ id: String, _ name: String, favorite: Bool = false, age: TimeInterval = 0, temperature: Double? = 21) -> Sensor {
        let date = now.addingTimeInterval(-age)
        var s = Sensor(id: id, date: date, rssi: -60, reading: Reading(date: date, temperature: temperature, humidity: 40))
        s.name = name; s.favorite = favorite
        return s
    }

    func testFavoritesOnlyWhenAnyExist() {
        let result = MenuSelection.rows([sensor("1", "Attic"), sensor("2", "Sauna", favorite: true)], now: now)
        XCTAssertEqual(result.rows.map(\.id), ["2"])
        XCTAssertEqual(result.overflow, 0)
    }

    func testAllTagsSortedByNameWhenNoFavorites() {
        let result = MenuSelection.rows([sensor("1", "sauna"), sensor("2", "Attic"), sensor("3", "Tag 10"), sensor("4", "Tag 9")], now: now)
        XCTAssertEqual(result.rows.map(\.name), ["Attic", "sauna", "Tag 9", "Tag 10"])
    }

    func testSidebarOrderPutsFavoritesFirst() {
        let sorted = [sensor("1", "Attic"), sensor("2", "Zoo", favorite: true)].sorted(by: MenuSelection.sidebarOrder)
        XCTAssertEqual(sorted.map(\.id), ["2", "1"])
    }

    func testCapAndOverflow() {
        let sensors = (0..<11).map { sensor("\($0)", String(format: "Tag %02d", $0), favorite: true) }
        let result = MenuSelection.rows(sensors, now: now)
        XCTAssertEqual(result.rows.count, 8)
        XCTAssertEqual(result.overflow, 3)
        XCTAssertEqual(result.rows.first?.name, "Tag 00")
    }

    func testStaleBoundary() {
        XCTAssertFalse(MenuSelection.isStale(sensor("1", "A", age: 30), now: now))
        XCTAssertTrue(MenuSelection.isStale(sensor("1", "A", age: 30.5), now: now))
        let rows = MenuSelection.rows([sensor("1", "A", age: 31), sensor("2", "B", age: 5)], now: now).rows
        XCTAssertEqual(rows.map(\.stale), [true, false])
    }

    func testEmptyAndMissingValues() {
        XCTAssertTrue(MenuSelection.rows([], now: now).rows.isEmpty)
        let row = MenuSelection.rows([sensor("1", "A", temperature: nil)], now: now).rows[0]
        XCTAssertNil(row.temperature)
        XCTAssertEqual(row.humidity, 40)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --build-system native --filter MenuSelectionTests`
Expected: compile failure, `cannot find 'MenuSelection' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/RuuviCore/MenuSelection.swift`:

```swift
import Foundation

public struct MenuRow: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let temperature: Double?
    public let humidity: Double?
    public let stale: Bool
}

/// Tag rows for the menu bar extra: favorites, or every tag when there are none, in sidebar order.
public enum MenuSelection {
    public static let defaultLimit = 8
    public static let staleAfter: TimeInterval = 30
    public static func sidebarOrder(_ a: Sensor, _ b: Sensor) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    public static func isStale(_ sensor: Sensor, now: Date) -> Bool {
        now.timeIntervalSince(sensor.lastSeen) > staleAfter
    }
    public static func rows(_ sensors: [Sensor], now: Date, limit: Int = defaultLimit) -> (rows: [MenuRow], overflow: Int) {
        let favorites = sensors.filter(\.favorite)
        let chosen = (favorites.isEmpty ? sensors : favorites).sorted(by: sidebarOrder)
        let rows = chosen.prefix(limit).map {
            MenuRow(id: $0.id, name: $0.name, temperature: $0.latest.temperature,
                    humidity: $0.latest.humidity, stale: isStale($0, now: now))
        }
        return (rows, max(0, chosen.count - limit))
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --build-system native --filter MenuSelectionTests`
Expected: 6 tests pass.

- [ ] **Step 5: Use the shared order in the sidebar**

In `ContentView` replace the inline sort closure:

```swift
                    ForEach(store.sensors.filter { !favoritesOnly || $0.favorite }.sorted(by: MenuSelection.sidebarOrder)) { sensor in
```

- [ ] **Step 6: Run all tests**

Run: `swift test --build-system native`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RuuviCore/MenuSelection.swift Sources/RuuviMac/RuuviMacApp.swift Tests/RuuviCoreTests/MenuSelectionTests.swift
git commit -m "Add tested tag selection and ordering for the menu bar"
```

---

### Task 3: App delegate, single window and Dock icon handling

**Files:**
- Create: `Sources/RuuviMac/AppDelegate.swift`
- Create: `Sources/RuuviMac/WindowAccessor.swift`
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (`RuuviMacApp`, `ContentView` selection)

**Interfaces:**
- Consumes: `SensorStore()`, `store.persist()`.
- Produces:
  - `final class SelectionModel: ObservableObject { @Published var selected: String? }`
  - `final class AppDelegate: NSObject, NSApplicationDelegate { let store: SensorStore; let selection: SelectionModel; func registerMainWindow(_ window: NSWindow); func showMainWindow() }` plus a `var startHidden: Bool` hook used by Task 4.
  - `struct WindowAccessor: NSViewRepresentable { let onWindow: (NSWindow) -> Void }`
  - `ContentView(store:selection:)`.

This task is AppKit/SwiftUI lifecycle wiring with no unit-testable logic. Verification is a build plus the manual checks in Step 6.

- [ ] **Step 1: Window accessor**

Create `Sources/RuuviMac/WindowAccessor.swift`:

```swift
import SwiftUI
import AppKit

/// Reports the NSWindow hosting a SwiftUI view, so the delegate can follow the main window only
/// (the menu bar extra owns windows too).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}
```

- [ ] **Step 2: App delegate and selection model**

Create `Sources/RuuviMac/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI

final class SelectionModel: ObservableObject {
    @Published var selected: String?
}

/// Owns objects that must outlive the main window, and switches the Dock icon with it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SensorStore()
    let selection = SelectionModel()
    private var activity: NSObjectProtocol?
    private weak var mainWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    /// Set before or after the main window appears; whichever comes second hides it.
    var startHidden = false { didSet { hideIfNeeded() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keeps timers and scan delivery on time while windowless. Idle sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Collecting RuuviTag readings")
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
```

`orderOut` closes nothing, so `willClose` does not fire on a hidden login launch. `hideIfNeeded` sets `.accessory` itself.

- [ ] **Step 3: Single `Window` scene owned through the delegate**

Replace `RuuviMacApp` in `Sources/RuuviMac/RuuviMacApp.swift`:

```swift
@main
struct RuuviMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("RuuviMac", id: "main") {
            ContentView(store: delegate.store, selection: delegate.selection)
                .frame(minWidth: 800, minHeight: 540)
                .background(WindowAccessor { delegate.registerMainWindow($0) })
        }
    }
}
```

This removes the `willTerminateNotification` `.onReceive`; the delegate saves now.

In `ContentView`, replace `@State private var selection: String?` with `@ObservedObject var selection: SelectionModel` and change `List(selection: $selection)` to `List(selection: $selection.selected)` and `store.sensors.first(where: { $0.id == selection })` to `store.sensors.first(where: { $0.id == selection.selected })`.

- [ ] **Step 4: Build**

Run: `swift build --build-system native` then `./scripts/build-app.sh`
Expected: builds without errors.

- [ ] **Step 5: Run tests**

Run: `swift test --build-system native`
Expected: all pass.

- [ ] **Step 6: Manual check**

Run `open dist/RuuviMac.app`. Then:
1. Close the window with the red button. The app keeps running (`pgrep -x RuuviMac` prints a pid) and the Dock icon disappears.
2. `open dist/RuuviMac.app` again. The window comes back once, the Dock icon returns, the earlier selection is still shown.
3. Cmd-Q quits.

Write the results in the task report.

- [ ] **Step 7: Commit**

```bash
git add Sources/RuuviMac/AppDelegate.swift Sources/RuuviMac/WindowAccessor.swift Sources/RuuviMac/RuuviMacApp.swift
git commit -m "Keep running after the window closes and hide the Dock icon while windowless"
```

---

### Task 4: Open at login

**Files:**
- Create: `Sources/RuuviMac/LoginItem.swift`
- Modify: `Sources/RuuviMac/AppDelegate.swift` (own `LoginItem`, launch detection, refresh on activate)
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (bottom bar toggle; pass `loginItem` to `ContentView`)

**Interfaces:**
- Consumes: `AppDelegate.startHidden` from Task 3.
- Produces:
  - `final class LoginItem: ObservableObject { @Published private(set) var enabled: Bool; @Published private(set) var needsApproval: Bool; @Published private(set) var message: String?; func refresh(); func set(_ on: Bool); func openSettings() }`
  - `enum LaunchReason { static func isLoginItemLaunch() -> Bool }`
  - `AppDelegate.loginItem: LoginItem`; `ContentView(store:selection:loginItem:)`.

- [ ] **Step 1: Login item wrapper**

Create `Sources/RuuviMac/LoginItem.swift`:

```swift
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
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
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
```

- [ ] **Step 2: Wire into the delegate**

In `AppDelegate`, add `let loginItem = LoginItem()` and `private var activeObserver: NSObjectProtocol?`. At the end of `applicationDidFinishLaunching` add:

```swift
        if LaunchReason.isLoginItemLaunch() { startHidden = true }
        // Returning from System Settings → Login Items should show the new state.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.loginItem.refresh()
        }
```

If detection returns false on a real login launch, the window shows as on a normal launch. That is the accepted fallback.

- [ ] **Step 3: Bottom bar toggle**

Change `ContentView` to take `@ObservedObject var loginItem: LoginItem` and pass `delegate.loginItem` from `RuuviMacApp`. In the bottom bar `HStack`, before `Button("MQTT settings…")`, add:

```swift
                Toggle("Open at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                    .toggleStyle(.checkbox)
                if loginItem.needsApproval {
                    Button("Approve in Login Items…") { loginItem.openSettings() }
                }
                if let message = loginItem.message { Text(message).font(.caption).foregroundStyle(.red) }
```

- [ ] **Step 4: Build and test**

Run: `swift test --build-system native && ./scripts/build-app.sh`
Expected: pass and build.

- [ ] **Step 5: Manual check of registration location**

1. Run `dist/RuuviMac.app`, tick "Open at login". Record `SMAppService` status shown (enabled, needs approval, or error text).
2. Copy the app to `/Applications` (`ditto dist/RuuviMac.app /Applications/RuuviMac.app`), quit the dist copy, launch the `/Applications` copy, untick and tick again. Record the result.
3. Untick before leaving the task unless the user asked to keep it.

Write both results in the task report; Task 6 copies them into README and VALIDATION.

- [ ] **Step 6: Commit**

```bash
git add Sources/RuuviMac/LoginItem.swift Sources/RuuviMac/AppDelegate.swift Sources/RuuviMac/RuuviMacApp.swift
git commit -m "Add open at login and start windowless when launched at login"
```

---

### Task 5: Menu bar extra

**Files:**
- Create: `Sources/RuuviMac/MenuBarView.swift`
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (add the `MenuBarExtra` scene)

**Interfaces:**
- Consumes: `MenuSelection.rows(_:now:)`, `MenuRow` (Task 2); `AppDelegate.showMainWindow()`, `SelectionModel` (Task 3); `LoginItem` (Task 4); `value(_:unit:)` in `RuuviMacApp.swift`; `store.status`.
- Produces: `struct MenuBarView: View` with `init(store:selection:loginItem:delegate:)`; `final class Ticker: ObservableObject`.

Staleness note: the spec names `TimelineView` for the clock-driven refresh. Menu-style `MenuBarExtra` content is turned into an `NSMenu`, where `TimelineView` is not a dependable redraw source, so this task uses a 10 second `Ticker` published value instead. Same behavior: rows go stale without a new reading.

Login status note: the spec also asks to re-read login item status when the menu opens. Menu-style content has no reliable open event, so the status is re-read when the app becomes active (Task 4), after every toggle, and on each `Ticker` tick (Step 1 adds `.onReceive(ticker.$now) { _ in loginItem.refresh() }` to the menu's first item). That keeps it within 10 seconds of a change made in System Settings.

- [ ] **Step 1: Menu view**

Create `Sources/RuuviMac/MenuBarView.swift`:

```swift
import SwiftUI
import AppKit
import RuuviCore

/// Publishes the time every 10 seconds so stale rows update while no readings arrive.
final class Ticker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.now = Date() }
    }
}

struct MenuBarView: View {
    @ObservedObject var store: SensorStore
    @ObservedObject var selection: SelectionModel
    @ObservedObject var loginItem: LoginItem
    let delegate: AppDelegate
    @StateObject private var ticker = Ticker()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let result = MenuSelection.rows(store.sensors, now: ticker.now)
        Text(result.rows.isEmpty ? "No sensors yet" : "RuuviTags")
            .onReceive(ticker.$now) { _ in loginItem.refresh() }
        ForEach(result.rows) { row in
            Button { open(select: row.id) } label: {
                Text("\(row.name)   \(value(row.temperature, unit: "°C"))   \(value(row.humidity, unit: "%"))\(row.stale ? "   stale" : "")")
            }
            .foregroundStyle(row.stale ? .secondary : .primary)
        }
        if result.overflow > 0 {
            Button("\(result.overflow) more…") { open(select: nil) }
        }
        Divider()
        Text(store.status)
        if store.savingPaused { Text("Saving paused") }
        Divider()
        Button("Open RuuviMac…") { open(select: nil) }
        Toggle("Open at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
        Button("Quit RuuviMac") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(select id: String?) {
        if let id { selection.selected = id }
        delegate.showMainWindow()
        openWindow(id: "main")
    }
}
```

Disabled `Button` items render greyed in `NSMenu` but cannot be clicked, so stale rows stay enabled and are marked with "stale" text; `foregroundStyle` is best effort in menu style.

- [ ] **Step 2: Add the scene**

In `RuuviMacApp.body`, after the `Window` scene:

```swift
        MenuBarExtra("RuuviMac", systemImage: "sensor.tag.radiowaves.forward") {
            MenuBarView(store: delegate.store, selection: delegate.selection,
                        loginItem: delegate.loginItem, delegate: delegate)
        }
        .menuBarExtraStyle(.menu)
```

- [ ] **Step 3: Build and test**

Run: `swift test --build-system native && ./scripts/build-app.sh`
Expected: pass and build.

- [ ] **Step 4: Manual check**

Launch `dist/RuuviMac.app` with a RuuviTag nearby:
1. The menu bar icon appears. The menu lists tags with temperature and humidity.
2. Close the main window. Open the menu twice about 30 seconds apart. Values change.
3. Click a tag row. The window opens with that tag selected and the Dock icon back. Click "Open RuuviMac…" again. Still one window.
4. "Quit RuuviMac" with the window closed. Relaunch. The latest reading is present.

Write results in the task report.

- [ ] **Step 5: Commit**

```bash
git add Sources/RuuviMac/MenuBarView.swift Sources/RuuviMac/RuuviMacApp.swift
git commit -m "Add menu bar extra with live tag readings"
```

---

### Task 6: Docs and smoke test

**Files:**
- Modify: `README.md` ("Data and behavior", "Validation and limitations" sections; add a "Menu bar and background collection (v0.4)" section after "Download stored RuuviTag history (v0.3)")
- Modify: `VALIDATION.md` (new "Background and menu bar v0.4" section)
- Modify: `Resources/Info.plist` (`CFBundleShortVersionString` 0.4.0, `CFBundleVersion` 5)

**Interfaces:**
- Consumes: manual results recorded in Tasks 3 to 5.
- Produces: nothing used by code.

- [ ] **Step 1: README section**

Add after the v0.3 section:

```markdown
## Menu bar and background collection (v0.4)

RuuviMac keeps running after you close its window. The Dock icon goes away and the sensor icon stays in the menu bar. The menu lists your favorite tags, or all tags if none are favorites, with temperature and humidity. Tags not heard for 30 seconds are marked stale. Click a tag to open it in the window. **Quit RuuviMac** in the menu stops collection.

Turn on **Open at login** in the menu or the window to start collecting after you log in. A login launch starts in the menu bar without a window. <RESULT FROM TASK 4: which bundle locations registered, and whether approval in System Settings → General → Login Items was needed.>

Collection still needs the Mac to be awake. RuuviMac does not prevent sleep. After wake, Bluetooth scanning resumes and MQTT reconnects.

If saved data cannot be read at launch, RuuviMac pauses saving so the file is not overwritten, and keeps showing new readings. **Move aside and start fresh** renames the old file to `sensors.json.unreadable-<time>` and resumes saving.
```

Replace `<RESULT FROM TASK 4 ...>` with the recorded sentence. Do not leave the placeholder.

- [ ] **Step 2: Fix outdated README lines**

- In "Data and behavior", change "History records new measurement sequences at minute intervals while this Mac is awake and the app receives readings." to "History records new measurement sequences at minute intervals while this Mac is awake and the app is running, with or without its window."
- Change "A malformed archive is reported rather than silently ignored; move it aside to reset." to "A malformed archive is reported and saving pauses until you choose Move aside and start fresh."
- In "Validation and limitations", change "No cloud sync, alarms, background launch service, CSV export, or firmware updates in v0.3. The app must stay running and the Mac awake to collect samples." to "No cloud sync, alarms, CSV export, or firmware updates in v0.4. The app must be running, in the window or the menu bar, and the Mac awake to collect samples."

- [ ] **Step 3: Bump version**

In `Resources/Info.plist`: `CFBundleShortVersionString` to `0.4.0`, `CFBundleVersion` to `5`.

- [ ] **Step 4: Full smoke test**

Run `swift test --build-system native` and `./scripts/build-app.sh`, then the spec's checklist with a RuuviTag nearby:

1. Close the window. Dock icon gone, menu icon stays, menu readings update, history sample count rises after a few minutes.
2. Quit from the menu with the window closed. Relaunch. Latest reading present.
3. "Open RuuviMac…" restores the window and the Dock icon.
4. Enable open at login, log out and in. App starts windowless and collects. (Needs the user to log out; if not possible in this session, record as not run.)
5. Sleep and wake. Scanning resumes and readings update.
6. Windowless for 10 minutes. `stat -f %m` on the archive shows saves continuing.
7. Clicking a tag row selects it in the window. "Open RuuviMac…" twice gives one window.
8. Copy `sensors.json` aside, replace it with `{not json`, launch, let readings arrive, quit. `shasum` of the file is unchanged. Restore the original afterward.

The archive path is `~/Library/Containers/org.ruuvimac.app/Data/Library/Application Support/RuuviMac/sensors.json`.

- [ ] **Step 5: VALIDATION.md**

Add a "Background and menu bar v0.4" section listing: test count and result, Swift and Xcode versions (`swift --version`, `xcodebuild -version`), each smoke item as passed, failed, or not run with a one-line note. Report only what was run.

- [ ] **Step 6: Commit**

```bash
git add README.md VALIDATION.md Resources/Info.plist
git commit -m "Document menu bar and background collection for v0.4"
```
