import SwiftUI
import AppKit
import Charts
import RuuviCore

@main
struct RuuviMacApp: App {
    @StateObject private var store = SensorStore()
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 800, minHeight: 540)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.persist() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: SensorStore
    @State private var selection: String?
    @State private var favoritesOnly = false
    @State private var mqttSettings = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Toggle("Favorites only", isOn: $favoritesOnly).padding()
                List(selection: $selection) {
                    ForEach(store.sensors.filter { !favoritesOnly || $0.favorite }.sorted(by: MenuSelection.sidebarOrder)) { sensor in
                        HStack {
                            Image(systemName: sensor.favorite ? "star.fill" : "sensor.tag.radiowaves.forward")
                                .foregroundStyle(sensor.favorite ? Color.orange : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(sensor.name)
                                Text(value(sensor.latest.temperature, unit: "°C")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(sensor.id)
                    }
                }
            }.navigationTitle("RuuviMac")
        } detail: {
            if let sensor = store.sensors.first(where: { $0.id == selection }) {
                SensorDetail(sensor: sensor, store: store).id(sensor.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.system(size: 52)).foregroundStyle(.teal)
                    Text(store.sensors.isEmpty ? (store.usingMQTT ? "Waiting for MQTT readings" : "Bring a RuuviTag nearby") : "Select a sensor").font(.title2)
                    Text("Read temperature, humidity, and pressure directly over Bluetooth. No pairing or account needed.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                    Text("Supports RuuviTag RAWv2 (format 5). History is collected while this app runs.").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill((store.scanning || store.status.hasPrefix("MQTT subscribed")) ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(store.status).font(.caption)
                if store.savingPaused {
                    Text("Saving paused").font(.caption).foregroundStyle(.orange)
                    Button("Move aside and start fresh") { store.moveArchiveAside() }
                }
                Spacer()
                Button("MQTT settings…") { mqttSettings = true }.disabled(store.downloadingTag != nil)
                Button(store.usingMQTT ? "Use Bluetooth" : store.scanning ? "Pause scanning" : "Resume scanning") { store.toggleScanning() }.disabled(store.downloadingTag != nil)
            }.padding(12).background(.bar)
        }
        .sheet(isPresented: $mqttSettings) { MQTTSettingsView(store: store) }
        .alert("Storage problem", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.savingPaused { Button("Move aside and start fresh") { store.moveArchiveAside() } }
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct SensorDetail: View {
    let sensor: Sensor
    @ObservedObject var store: SensorStore
    @State private var name = ""
    @State private var metric = "Temperature"
    @State private var historyDays = 1
    private var points: [Reading] { sensor.history.filter { Date().timeIntervalSince($0.date) <= Double(historyDays * 86400) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    TextField("Sensor name", text: $name).font(.title).textFieldStyle(.plain)
                        .onSubmit { store.rename(sensor.id, to: name) }
                    Button("Save name") { store.rename(sensor.id, to: name) }
                    Button { store.favorite(sensor.id) } label: {
                        Image(systemName: sensor.favorite ? "star.fill" : "star")
                    }.help("Toggle favorite")
                }
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    HStack {
                        Text(context.date.timeIntervalSince(sensor.lastSeen) > 30 ? "No recent signal" : "Recent reading")
                        Text("Last seen \(sensor.lastSeen.formatted(date: .omitted, time: .standard)) · \(sensor.rssi) dBm")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    tile("Temperature", value(sensor.latest.temperature, unit: "°C"), "thermometer.medium")
                    tile("Humidity", value(sensor.latest.humidity, unit: "%"), "humidity")
                    tile("Pressure", value(sensor.latest.pressure, unit: "hPa"), "barometer")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("History").font(.headline)
                        Spacer()
                        Picker("Period", selection: $historyDays) {
                            Text("Last 24 hours").tag(1)
                            Text("Last 10 days").tag(10)
                        }.frame(width: 150)
                        Picker("Measurement", selection: $metric) {
                            Text("Temperature").tag("Temperature")
                            Text("Humidity").tag("Humidity")
                            Text("Pressure").tag("Pressure")
                        }.frame(width: 170)
                    }
                    Chart(points) { reading in
                        if let v = measurement(reading) {
                            LineMark(x: .value("Time", reading.date), y: .value(metric, v)).foregroundStyle(.teal)
                        }
                    }.chartYAxisLabel(metric == "Temperature" ? "°C" : metric == "Humidity" ? "%" : "hPa")
                        .frame(height: 220)
                    Text("\(points.count) samples · live readings and downloaded tag history")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(store.downloadingTag == sensor.id ? "Cancel history download" : "Download tag history") {
                        historyDays = 10; store.downloadHistory(sensor.id)
                    }.disabled(store.downloadingTag != nil && store.downloadingTag != sensor.id)
                    Text(store.logStatus).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Battery: \(value(sensor.latest.voltage, unit: "V"))")
                    Text("Movement: \(sensor.latest.movement.map(String.init) ?? "—")")
                    Text("TX: \(sensor.latest.txPower.map(String.init) ?? "—") dBm")
                }.font(.callout)
                Text("Acceleration: X \(value(sensor.latest.accelerationX, unit: "g")) · Y \(value(sensor.latest.accelerationY, unit: "g")) · Z \(value(sensor.latest.accelerationZ, unit: "g"))").font(.caption)
                Text(sensor.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(28)
        }.onAppear { name = sensor.name }
    }
    func measurement(_ r: Reading) -> Double? {
        metric == "Temperature" ? r.temperature : metric == "Humidity" ? r.humidity : r.pressure
    }
    func tile(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(text).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
func value(_ number: Double?, unit: String) -> String {
    guard let number, number.isFinite else { return "—" }
    return number.formatted(.number.precision(.fractionLength(unit == "V" || unit == "g" ? 3 : 1))) + " " + unit
}
