# Home Assistant MQTT bridge

Status: approved in conversation, 2026-10-07. Amended after Sol review the same day (Keychain type and failure handling, multi-Mac ownership, reliable removal, ordered shutdown, state after discovery). Sub-project 2 of 3. Depends on the background and menu bar work (`2026-10-07-background-menubar-design.md`).

## Goal

RuuviMac publishes the RuuviTags it hears over Bluetooth to a Home Assistant MQTT broker using MQTT discovery. Each tag appears in Home Assistant as a device with sensor entities, with no YAML configuration in Home Assistant. This serves setups where Home Assistant cannot hear the tags itself.

## Decisions

- MQTT device discovery. Rejected: pushing to the REST `/api/states` endpoint (states do not survive a Home Assistant restart, no device registry, needs a token) and an HTTP endpoint Home Assistant polls (inbound port, YAML required).
- Only Bluetooth-sourced readings are published. Readings from MQTT input already exist on a broker Home Assistant can use directly, and excluding them prevents an input to output loop when the input topic filter is broad.
- Only tags identified by MAC are published. The CoreBluetooth UUID fallback can change and would leave orphan entities.
- Several Macs may bridge to one broker. Each Mac has its own availability topic. Each tag must be published by exactly one Mac. The user enforces this with a per-tag publish switch. Tags heard by two Macs are not merged.
- The broker password is stored in the user's legacy file-based Keychain. MQTT input passwords stay session-only, as documented in v0.2.
- Home Assistant's default birth topic and payload (`<prefix>/status`, `online`) are assumed. A customized birth topic only loses the republish-on-restart trigger. Retained configs still work.
- Discovery format follows the Home Assistant MQTT integration docs (https://www.home-assistant.io/integrations/mqtt/), checked 2026-10-07: device discovery topic `<prefix>/device/<object_id>/config`, required `dev` and `o` maps, entities under `cmps` each with `p` and `unique_id`, retained configs, birth message, removal by empty retained config. The Sol review confirmed against Home Assistant's `discovery.py` that the abbreviations below are valid and that top-level `stat_t` and `avty_t` are inherited by components.

## Behavior

### Settings

A "Home Assistant…" sheet, opened from the main window bottom bar and the menu bar extra:

- Enable toggle.
- Broker host, port (default 1883), TLS toggle (system trust, same as MQTT input), username, password, discovery prefix (default `homeassistant`).
- "Publish newly discovered tags" toggle, default on. When off, new tags start with publishing off.
- A note that each tag should be published by one Mac only.
- Status line with the publisher state: disabled, connecting, connected, retrying (with reason), "Password unavailable from Keychain" (with "Try again"), or "N tags published".
- "Remove all devices from this broker" button: removes every tag this Mac has published (see Removal).
- Non-secret settings in `UserDefaults` under `ha.*` keys.
- Validation reuses the `MQTTSettings` host and port rules. The discovery prefix must be non-empty and contain no `+`, `#` or leading/trailing `/`.
- When enabled, the publisher starts at app launch, including launch at login, independent of the Bluetooth or MQTT input mode.

Changing broker or prefix does not delete configs on the old broker. The sheet says so and points to "Remove all devices from this broker" before switching.

### Password storage

- Legacy file-based Keychain through `SecItem` with `kSecClassGenericPassword`, without `kSecUseDataProtectionKeychain` and without synchronization. The data-protection Keychain needs provisioned access-group entitlements that ad-hoc signing cannot provide (Apple TN3137). Items go to the user's default Keychain, normally the login Keychain. The default caller-only ACL is kept.
- Service `org.ruuvimac.homeassistant`, account `username@host:port`.
- Save: `SecItemUpdate`, then `SecItemAdd` if not found. Never delete an existing password before the replacement succeeds. Changing username, host or port saves under the new account and deletes the old item only after that succeeds.
- An empty password field with a non-empty username is valid: no item is stored and the publisher connects with username only. An empty username means anonymous.
- All Keychain calls run on a background queue and deliver results on main. A login-time Keychain prompt left unanswered must not block Bluetooth handling or saves.
- Failure handling: item not found while a username is set, user denied, Keychain locked, interaction not allowed, or any other `OSStatus` error all produce "Password unavailable from Keychain" with the status code in the detail text, and the publisher does not connect. "Try again" repeats the read. Saving errors show in the sheet and keep the previous item.
- Ad-hoc rebuilds change the code signature, so macOS may ask for access again after a rebuild. "Always Allow" covers that build. The README says this.

### Identifiers

- `<mac>` is the 12 hex digit MAC, lowercase, no separators (for example `c4a1b2d3e4f5`).
- `<bridge>` is a random 8 hex digit id generated once per Mac and stored in `UserDefaults` (`ha.bridgeID`).
- Device discovery object id: `ruuvi_<mac>`.
- Device identifiers: `["ruuvimac_<mac>"]`.
- Entity unique ids: `ruuvimac_<mac>_<field>` where field is `temperature`, `humidity`, `pressure`, `voltage`, `rssi`, `movement`.

Device and entity ids do not include `<bridge>`, so moving a tag from one Mac to another keeps its Home Assistant entities and history.

### Topics and payloads

Availability: `ruuvimac/<bridge>/status`. Publish retained `online` after connect. MQTT Last Will is retained `offline` on the same topic. Each tag's config points at the availability topic of the Mac that publishes it.

Config: `<prefix>/device/ruuvi_<mac>/config`, retained, QoS 1:

```json
{
  "dev": {"ids": ["ruuvimac_<mac>"], "name": "<tag name>", "mf": "Ruuvi", "mdl": "RuuviTag", "cns": [["mac", "<AA:BB:CC:DD:EE:FF>"]]},
  "o": {"name": "RuuviMac", "sw": "<CFBundleShortVersionString>", "url": "<repo URL>"},
  "avty_t": "ruuvimac/<bridge>/status",
  "stat_t": "ruuvimac/<mac>/state",
  "cmps": {
    "temperature": {"p": "sensor", "unique_id": "ruuvimac_<mac>_temperature", "name": "Temperature", "dev_cla": "temperature", "stat_cla": "measurement", "unit_of_meas": "°C", "val_tpl": "{{ value_json.temperature }}", "exp_aft": 600},
    "humidity":    {"p": "sensor", "unique_id": "ruuvimac_<mac>_humidity", "name": "Humidity", "dev_cla": "humidity", "stat_cla": "measurement", "unit_of_meas": "%", "val_tpl": "{{ value_json.humidity }}", "exp_aft": 600},
    "pressure":    {"p": "sensor", "unique_id": "ruuvimac_<mac>_pressure", "name": "Pressure", "dev_cla": "atmospheric_pressure", "stat_cla": "measurement", "unit_of_meas": "hPa", "val_tpl": "{{ value_json.pressure }}", "exp_aft": 600},
    "voltage":     {"p": "sensor", "unique_id": "ruuvimac_<mac>_voltage", "name": "Battery voltage", "dev_cla": "voltage", "stat_cla": "measurement", "unit_of_meas": "V", "ent_cat": "diagnostic", "val_tpl": "{{ value_json.voltage }}", "exp_aft": 600},
    "rssi":        {"p": "sensor", "unique_id": "ruuvimac_<mac>_rssi", "name": "Signal strength", "dev_cla": "signal_strength", "stat_cla": "measurement", "unit_of_meas": "dBm", "ent_cat": "diagnostic", "val_tpl": "{{ value_json.rssi }}", "exp_aft": 600},
    "movement":    {"p": "sensor", "unique_id": "ruuvimac_<mac>_movement", "name": "Movement counter", "stat_cla": "measurement", "ent_cat": "diagnostic", "val_tpl": "{{ value_json.movement }}", "exp_aft": 600}
  }
}
```

State: `ruuvimac/<mac>/state`, not retained, QoS 0:

```json
{"temperature": 21.4, "humidity": 41.2, "pressure": 1003.1, "voltage": 2.95, "rssi": -71, "movement": 12, "ts": 1791370000}
```

Missing measurements are JSON `null`, which Home Assistant shows as unknown. Values use the app's existing units (°C, %, hPa, V, dBm).

Availability and expiry are separate. `exp_aft` of 600 seconds counts from Home Assistant's receipt of the last state message. With the 60 second throttle, a tag that leaves range goes unavailable between 9 and 10 minutes after its last advertisement. This covers tag history downloads, which pause scanning.

### When to publish

- State: at most once per tag per 60 seconds. The throttle resets for all tags on connect and on a Home Assistant birth message, and for one tag when it is re-enabled. After a reset, the next fresh reading is published immediately. Cached old readings are never replayed as fresh state.
- Config for a tag is published:
  - on its first state publish after each connect, just before the state,
  - for every enabled tag seen this session when `<prefix>/status` receives `online` (the publisher subscribes to it),
  - when the user renames the tag.
- Tags with publishing off, or with a pending removal, never get config or state, including on birth and rename.
- Readings are not queued while disconnected. Home Assistant wants live state, and local history already keeps the backlog.

### Per-tag controls

The sensor detail view has, when the publisher is enabled and the tag has a MAC id:

- "Publish to Home Assistant" switch. Turning it off stops this Mac publishing the tag and leaves the device in Home Assistant, so another Mac can own it. Stored in `UserDefaults` as a set of MAC ids.
- "Remove from Home Assistant" button. Turns the switch off and deletes the device from Home Assistant (below). Disabled while another removal for the tag is pending.

### Removal

- Removing a tag records a pending removal `{mac, host, port, prefix}` in `UserDefaults` before publishing anything.
- The publisher sends an empty retained payload at QoS 1 to the config topic. The pending entry is cleared only when the PUBACK arrives.
- If the publish fails or the app quits first, the pending removal stays. It is retried on every connect to a broker matching its host, port and prefix, before any other config publishing.
- The detail view shows "Removing…" while pending and "Removed" after acknowledgement.
- "Remove all devices from this broker" queues a removal for every tag this Mac has published to the current broker and prefix (tracked as a persisted set per broker).

### Shutdown

Disable, settings change and quit all use the same ordered shutdown:

1. Stop accepting new publishes and cancel retry timers.
2. Publish retained `offline` to the availability topic at QoS 1 and wait for the PUBACK.
3. `disconnect()`, then `shutdown()` the client.

On quit, the app delegate's `applicationShouldTerminate` returns `.terminateLater` while the publisher is connected and calls `reply(toApplicationShouldTerminate: true)` when shutdown completes or after 2 seconds, whichever comes first. If the `offline` publish fails or times out, the broker's Last Will covers it once the connection drops. If not connected, the app terminates immediately.

### Failure behavior

- Connect or publish failure: retry with exponential backoff 1 to 30 seconds, same as `MQTTInput`. Status line shows the reason.
- Broker rejects credentials: status says so. Retries continue at the 30 second ceiling.
- Keychain failures: see Password storage.
- Collection, local history and MQTT input are unaffected by publisher failures.

## Components

- `RuuviCore/HomeAssistantDiscovery.swift`: pure functions that build topics, config JSON and state JSON from a sensor id, name, bridge id and `Reading`. No networking.
- `RuuviCore/PublishThrottle.swift`: per-tag 60 second gate with reset for all or one tag.
- `RuuviCore/HomeAssistantRemovals.swift`: pending-removal and published-set bookkeeping, codable for `UserDefaults`.
- `RuuviMQTT/HomeAssistantPublisher.swift`: MQTTNIO client with Last Will, reconnect, birth subscription, ordered shutdown, `publish(id:name:reading:rssi:)` and removal processing. State confined to the main queue like `MQTTInput`.
- `RuuviMac/HomeAssistantSettingsView.swift`: sheet.
- `RuuviMac/Keychain.swift`: generic password read and save on a background queue, with typed errors.
- `RuuviMac/SensorStore.swift`: `receive` gains a `source` (`.bluetooth`, `.mqtt`). Bluetooth readings with MAC ids and publishing on are forwarded to the publisher. Renames trigger config republish.
- `RuuviMac/RuuviMacApp.swift`: `applicationShouldTerminate` deferral.
- README and VALIDATION.md sections.

## Testing

Unit tests:

- Config JSON for a known tag matches the expected structure field by field (decode and compare, not string match), including the bridge availability topic.
- State JSON with all values and with missing values (`null`).
- MAC to object id sanitizing. UUID-identified tags rejected.
- Throttle: second reading within 60 seconds dropped, after 60 seconds sent, reset-all and reset-one send immediately.
- Source filtering: MQTT-sourced readings never reach the publisher.
- Disabled and pending-removal tags get no config on birth or rename.
- Removal bookkeeping: entry persists until acknowledged; only retried against a matching broker and prefix.
- Discovery prefix validation.

Loopback broker test, gated by `RUUVI_MQTT_TEST_PORT` like the existing one:

- Retained config arrives on `homeassistant/device/ruuvi_<mac>/config`.
- `online` retained on `ruuvimac/<bridge>/status` after connect.
- Dropping the connection produces the `offline` will. Ordered shutdown produces a retained `offline` before disconnect.
- Publishing `online` to `homeassistant/status` triggers a config republish and the next reading is published without waiting for the throttle.
- Removal publishes an empty retained config; after a forced failure it is retried on reconnect.

Manual:

- Keychain across rebuilds: build A, save password, build B, launch normally and at login. Record the prompt behavior, "Always Allow", denial and "Try again".
- Against the user's Home Assistant: device appears with six entities, values match the app, rename updates the device name, entities go unavailable about 10 minutes after the tag leaves range, quitting marks them unavailable, "Remove" deletes the device.
- Two bridge ids against one broker (second instance or changed `ha.bridgeID`): quitting one does not mark the other's tags unavailable.
