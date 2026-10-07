import SwiftUI
import RuuviCore

struct HomeAssistantSettingsView: View {
    @ObservedObject var bridge: HomeAssistantBridge
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var host = ""
    @State private var port = 1883
    @State private var tls = false
    @State private var username = ""
    @State private var password = ""
    @State private var clearPassword = false
    @State private var prefix = ""
    @State private var publishNewTags = true
    @State private var issue: String?
    @State private var confirmRemoveAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Home Assistant").font(.title2)
            Text("Publish RuuviTags heard over Bluetooth to your Home Assistant MQTT broker. Each tag appears as a device through MQTT discovery.")
                .foregroundStyle(.secondary)
            Form {
                Toggle("Publish to Home Assistant", isOn: $enabled)
                TextField("Broker hostname", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Use TLS with trusted certificates", isOn: $tls)
                TextField("Username", text: $username)
                SecureField(bridge.hasPassword ? "Password (leave empty to keep the saved one)" : "Password (optional)", text: $password)
                    .disabled(clearPassword)
                if bridge.hasPassword {
                    Toggle("Remove the saved password", isOn: $clearPassword)
                        .onChange(of: clearPassword) { on in if on { password = "" } }
                }
                TextField("Discovery prefix", text: $prefix)
                Toggle("Publish newly discovered tags", isOn: $publishNewTags)
            }
            Text("Publish each tag from one Mac only. Turn off publishing for a tag on the other Macs. Changing the broker or prefix leaves devices on the old broker; remove them first.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Circle().fill(bridge.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(bridge.status).font(.caption).lineLimit(2)
                if bridge.keychainProblem { Button("Try again") { bridge.retryKeychain() } }
            }
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Remove all devices from this broker…") { confirmRemoveAll = true }
                    .disabled(!bridge.enabled)
                Spacer()
                if bridge.saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.disabled(bridge.saving)
                Button("Save") {
                    issue = nil
                    let settings = HomeAssistantSettings(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                        tls: tls, username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines), publishNewTags: publishNewTags)
                    bridge.apply(settings: settings, enabled: enabled, password: password, clearPassword: clearPassword) { problem in
                        if let problem { issue = problem } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bridge.saving)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(bridge.saving)
        .onAppear {
            let s = bridge.settings
            enabled = bridge.enabled; host = s.host; port = s.port; tls = s.tls; username = s.username
            prefix = s.prefix; publishNewTags = s.publishNewTags
        }
        .confirmationDialog("Remove every tag this Mac publishes to this broker from Home Assistant?",
                            isPresented: $confirmRemoveAll) {
            Button("Remove all", role: .destructive) { bridge.removeAll() }
        }
    }
}
