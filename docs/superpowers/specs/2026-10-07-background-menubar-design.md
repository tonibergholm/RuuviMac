# Background collection and menu bar extra

Status: approved in conversation, 2026-10-07. Sub-project 1 of 3 (background and menu bar, then Home Assistant bridge, then widget spike).

## Goal

RuuviMac keeps collecting readings when its window is closed and can start at login, so it can serve as an unattended Bluetooth collector and, later, a Home Assistant bridge. A menu bar extra shows current readings and controls the app.

## Decisions

- The app stays resident in the menu bar. One process and one data store. A separate login-item helper was rejected as more work than this needs.
- No Dock icon while no window is open.
- The Mac must be awake to collect. The app does not prevent idle or system sleep.
- Desktop widgets are out of scope. A separate spike decides feasibility.

## Behavior

### Lifecycle

- A `MenuBarExtra` scene sits beside the existing `WindowGroup`. Its icon is the `sensor.tag.radiowaves.forward` glyph and stays visible while the app runs.
- Closing the last window does not quit the app. When no window is visible, the activation policy becomes `.accessory`, which removes the Dock icon. Opening a window sets it back to `.regular` and activates the app.
- "Open RuuviMac…" in the menu opens or focuses the main window with `openWindow`.
- "Quit RuuviMac" in the menu terminates the app. Cmd-Q in the main window also quits.
- Persist-on-terminate moves from `ContentView.onReceive` to an `NSApplicationDelegate` (via `NSApplicationDelegateAdaptor`) that calls `store.persist()` in `applicationWillTerminate`. The current hook only exists while the window exists, so quitting from the menu bar would otherwise skip the final save.
- The store is owned by the delegate (or the `App` struct) and shared with both scenes, so closing the window does not deallocate it.
- The app holds one `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason:)` token for its lifetime. This prevents App Nap from throttling the save debounce, MQTT retry timers and scan delivery while windowless, without blocking sleep.
- After wake, CoreBluetooth's state callback restarts scanning (existing `centralManagerDidUpdateState` path) and MQTT input uses its existing reconnect. No new wake handling unless the smoke test shows scanning does not resume.

### Open at login

- A menu item and a matching toggle in the main window bottom bar: "Open at login". Off by default.
- Implemented with `SMAppService.mainApp.register()` / `unregister()`. The toggle reflects `SMAppService.mainApp.status`: enabled, not registered, or requires approval. For requires approval, show "Approve in System Settings → General → Login Items" with a button calling `SMAppService.openSystemSettingsLoginItems()`.
- Registration errors appear as a status message, not an alert loop.
- When launched at login the app starts windowless (accessory policy). Detection: at launch, read the current open-application Apple event from `NSAppleEventManager` and check its `keyAEPropData` parameter for `keyAELaunchedAsLogInItem`. A normal launch shows the window. If the check proves unreliable with `SMAppService`, the fallback is to show the window. That is harmless, and the smoke test records which happened.
- Verification step: confirm registration works for an ad-hoc signed bundle run from `dist/` and from `/Applications`. Document which locations work in the README.

### Menu content

Top to bottom:

1. Tag rows: favorites, or all tags when none are favorites, sorted as in the sidebar. At most 8 rows, then "N more…" which opens the window. Each row shows name, temperature and humidity using the existing `value(_:unit:)` formatter. Rows for tags not heard for over 30 seconds are dimmed with "stale" text. Clicking a row opens the window with that tag selected.
2. Status line: the existing `store.status`.
3. "Open RuuviMac…", "Open at login" (checkmark), "Quit RuuviMac".

Use the menu (`.menu`) style for macOS 13 compatibility. Rows refresh with the store's `@Published` updates. The menu does not need to animate.

Empty state: "No sensors yet" plus the status line.

## Out of scope

- Live temperature in the menu bar title.
- Preventing sleep or `caffeinate` style behavior.
- Persisting MQTT input passwords (stays session-only, see Home Assistant spec for output).
- WidgetKit.

## Files

- `Sources/RuuviMac/RuuviMacApp.swift`: scenes, app delegate, activation policy, activity token.
- New `Sources/RuuviMac/MenuBarView.swift`: menu content.
- New `Sources/RuuviMac/LoginItem.swift`: small wrapper around `SMAppService.mainApp` with a published status.
- `Sources/RuuviMac/SensorStore.swift`: a pure helper for menu tag selection and ordering (favorites, else all, sorted, capped) moved to `RuuviCore` so it can be unit tested.
- `README.md`: replace "No ... background launch service" and "The app must stay running" text with the menu bar and open-at-login behavior and the awake requirement.
- `VALIDATION.md`: new section with results.
- `.gitignore`: add `.worktrees/`.

## Testing

Unit tests (XCTest, `RuuviCoreTests`):

- Menu selection: favorites only when any exist; all tags otherwise; sort order matches sidebar; cap and overflow count; stale flag at the 30 second boundary.

Manual smoke checklist, recorded in VALIDATION.md:

1. Close the window. The Dock icon disappears, the menu bar icon stays, readings in the menu keep updating, and history samples keep arriving (check sample count after a few minutes).
2. Quit from the menu with the window closed. Relaunch. The latest reading from just before quit is present.
3. "Open RuuviMac…" restores the window and the Dock icon.
4. Enable open at login, log out and in. The app starts windowless and collects.
5. Sleep and wake the Mac. Scanning resumes and readings update.
6. Leave the app windowless for 10 minutes. Saves still happen roughly every 5 seconds of activity (check archive modification time).
7. Clicking a tag row selects it in the window.
