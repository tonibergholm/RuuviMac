import SwiftUI
import AppKit
import RuuviCore

/// Publishes the time every 10 seconds so stale rows update while no readings arrive.
final class Ticker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?
    init() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.now = Date() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate() }
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
        Toggle("Open at login", isOn: Binding(get: { loginItem.registered }, set: { loginItem.set($0) }))
        if loginItem.needsApproval { Button("Approve in Login Items…") { loginItem.openSettings() } }
        if let message = loginItem.message { Text(message) }
        Button("Quit RuuviMac") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(select id: String?) {
        if let id { selection.selected = id }
        delegate.showMainWindow()
        openWindow(id: "main")
    }
}
