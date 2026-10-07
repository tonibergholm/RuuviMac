# Home Assistant MQTT bridge

Status: approved in conversation, 2026-10-07. Sub-project 2 of 3. Depends on the background and menu bar work (`2026-10-07-background-menubar-design.md`).

## Goal

RuuviMac publishes the RuuviTags it hears over Bluetooth to a Home Assistant MQTT broker using MQTT discovery. Each tag appears in Home Assistant as a device with sensor entities, with no YAML configuration in Home Assistant. This serves setups where Home Assistant cannot hear the tags itself.

## Decisions

- MQTT device discovery. Rejected: pushing to the REST `/api/states` endpoint (states do not survive a Home Assistant restart, no device registry, needs a token) and an HTTP endpoint Home Assistant polls (inbound port, YAML required).
- Only Bluetooth-sourced readings are published. Readings from MQTT input already exist on a broker Home Assistant can use directly, and excluding them prevents an input to output loop when the input topic filter is broad.
- Only tags identified by MAC are published. The CoreBluetooth UUID fallback can change and would leave orphan entities.
- The broker password is stored in the login Keychain. MQTT input passwords stay session-only, as documented in v0.2.
- Discovery format follows the Home Assistant MQTT integration docs (https://www.home-assistant.io/integrations/mqtt/), checked 2026-10-07: device discovery topic `<prefix>/device/<object_id>/config`, required `dev` and `o` maps, entities under `cmps` each with `p` and `unique_id`, retained configs, birth message `online` on `homeassistant/status`, removal by empty retained config.

## Behavior

### Settings

A "Home Assistant…" sheet, opened from the main window bottom bar and the menu bar extra:

- Enable toggle.
- Broker host, port (default 1883), TLS toggle (system trust, same as MQTT input), username, password, discovery prefix (default `homeassistant`).
- Status line with the publisher state: disabled, connecting, connected, retrying (with reason), or "N tags published".
- Non-secret settings in `UserDefaults` under `ha.*` keys. Password in the Keychain as a generic password (service `org.ruuvimac.homeassistant`, account = `username@host:port`).
- Validation reuses the `MQTTSettings` host and port rules. The discovery prefix must be non-empty and contain no `+`, `#` or leading/trailing `/`.
- When enabled, the publisher starts at app launch, including launch at login, independent of the Bluetooth or MQTT input mode.

Keychain note for the README: with ad-hoc signing, the Keychain item's access control is tied to the binary's code signature, so macOS may ask "allow access" after each rebuild. "Always Allow" covers that build.

### Identifiers

`<mac>` is the 12 hex digit MAC, lowercase, no separators (for example `c4a1b2d3e4f5`).

- Device discovery object id: `ruuvi_<mac>`.
- Device identifiers: `["ruuvimac_<mac>"]`.
- Entity unique ids: `ruuvimac_<mac>_<field>` where field is `temperature`, `humidity`, `pressure`, `voltage`, `rssi`, `movement`.

### Topics and payloads

Availability: `ruuvimac/bridge/status`. Publish retained `online` after connect. Configure the MQTT Last Will as retained `offline` on the same topic. Publish retained `offline` before a clean disconnect (disable, quit).

Config: `<prefix>/device/ruuvi_<mac>/config`, retained, QoS 1:

```json
{
  "dev": {"ids": ["ruuvimac_<mac>"], "name": "<tag name>", "mf": "Ruuvi", "mdl": "RuuviTag", "cns": [["mac", "<AA:BB:CC:DD:EE:FF>"]]},
  "o": {"name": "RuuviMac", "sw": "<CFBundleShortVersionString>", "url": "<repo URL>"},
  "avty_t": "ruuvimac/bridge/status",
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

The implementation verifies each abbreviation and the shared top-level `stat_t` / `avty_t` against the current Home Assistant abbreviation list before finalizing. If shared top-level options are not inherited by components in device discovery, put them on each component.

State: `ruuvimac/<mac>/state`, not retained, QoS 0:

```json
{"temperature": 21.4, "humidity": 41.2, "pressure": 1003.1, "voltage": 2.95, "rssi": -71, "movement": 12, "ts": 1791370000}
```

Missing measurements are JSON `null`. Values use the app's existing units (°C, %, hPa, V, dBm).

`exp_aft` of 600 seconds marks a tag unavailable after 10 minutes without a state. This covers tag history downloads, which pause scanning.

### When to publish

- State: at most once per tag per 60 seconds. The first reading for a tag after each connect is sent immediately.
- Config for a tag is published:
  - on its first state publish after each connect,
  - for all tags seen this session when `homeassistant/status` receives `online` (the publisher subscribes to it),
  - when the user renames the tag.
- Readings are not queued while disconnected. Home Assistant wants live state, and local history already keeps the backlog.

### Remove from Home Assistant

The sensor detail view has "Remove from Home Assistant" when the publisher is enabled. It publishes an empty retained payload to the tag's config topic and stops publishing that tag until the user re-adds it (button becomes "Publish to Home Assistant"). The excluded set persists in `UserDefaults`.

### Failure behavior

- Connect or publish failure: retry with exponential backoff 1 to 30 seconds, same as `MQTTInput`. Status line shows the reason.
- Broker rejects credentials: status says so. Retries continue at the 30 second ceiling.
- Keychain read fails or the user denies access: status "Password unavailable from Keychain". The publisher does not connect with an empty password unless username is also empty.
- Collection, local history and MQTT input are unaffected by publisher failures.

## Components

- `RuuviCore/HomeAssistantDiscovery.swift`: pure functions that build topics, config JSON and state JSON from a sensor id, name and `Reading`. No networking.
- `RuuviCore/PublishThrottle.swift` (or inside the publisher if small): per-tag 60 second gate with reset on connect.
- `RuuviMQTT/HomeAssistantPublisher.swift`: MQTTNIO client with LWT, reconnect, birth subscription, and `publish(id:name:reading:rssi:)`. State confined to the main queue like `MQTTInput`.
- `RuuviMac/HomeAssistantSettingsView.swift`: sheet.
- `RuuviMac/Keychain.swift`: generic password read/write/delete via Security framework.
- `RuuviMac/SensorStore.swift`: `receive` gains a `source` (`.bluetooth`, `.mqtt`); Bluetooth readings with MAC ids are forwarded to the publisher; renames trigger config republish.
- README and VALIDATION.md sections.

## Testing

Unit tests:

- Config JSON for a known tag matches the expected structure field by field (decode and compare, not string match).
- State JSON with all values and with missing values (`null`).
- MAC to object id sanitizing; UUID-identified tags rejected.
- Throttle: second reading within 60 seconds dropped, after 60 seconds sent, reset on reconnect sends immediately.
- Source filtering: MQTT-sourced readings never reach the publisher.
- Discovery prefix validation.

Loopback broker test, gated by `RUUVI_MQTT_TEST_PORT` like the existing one:

- Retained config arrives on `homeassistant/device/ruuvi_<mac>/config`.
- `online` retained on the availability topic after connect.
- Killing the client connection produces the `offline` will.
- Publishing `online` to `homeassistant/status` triggers a config republish.

Manual, against the user's Home Assistant: device appears with six entities, values match the app, rename updates the device name, entities go unavailable 10 minutes after the tag leaves range, "Remove" deletes the device.

## Review

Before planning, an independent Sol review of this spec, focused on credential storage and the MQTT topic and retention design.
