import SwiftUI
import RuuviCore

struct MQTTSettingsView: View {
    @ObservedObject var store: SensorStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mqtt.host") private var host = "localhost"
    @AppStorage("mqtt.port") private var port = 1883
    @AppStorage("mqtt.topic") private var topic = "ruuvi/#"
    @AppStorage("mqtt.username") private var username = ""
    @AppStorage("mqtt.tls") private var tls = false
    @State private var password = ""
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MQTT input").font(.title2)
            Text("Accept Ruuvi Gateway, ruuvi-go-gateway, or RuuviBridge messages.").foregroundStyle(.secondary)
            Form {
                TextField("Broker hostname", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Topic filter", text: $topic)
                TextField("Username", text: $username)
                SecureField("Password (this session)", text: $password)
                Toggle("Use TLS with trusted certificates", isOn: $tls)
            }
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Use Bluetooth") { store.useBluetooth(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect MQTT") {
                    let config = MQTTSettings(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                        topic: topic, username: username, password: password, tls: tls)
                    if let error = config.validationError { issue = error }
                    else { store.useMQTT(config); dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 510)
    }
}
