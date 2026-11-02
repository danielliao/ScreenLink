# Changelog

## 0.4.0 — Workstation sharing

- Add observed manual-unlock relay through the coordinator, with remote-origin suppression and no password retries.
- Defer automatic locks for mouse/keyboard activity in the preceding ten seconds, including follower activity and secure-input uncertainty; cancel stale automatic commands.
- Add group pause/resume presets, monotonic restart-safe deadlines and per-device acknowledgement status.
- Add opt-in encrypted text/image clipboard sharing with duplicate suppression, deterministic ordering and sensitive-type filtering.
- Add authenticated encrypted streaming file transfer by dropping files on a device or the all-devices area, with progress, cancellation, bounded queues, safe staging and no-clobber publication.
- Preserve legacy settings and negotiate new control capabilities. All three Macs should upgrade for group automation.

## 0.3.1 — Local lock recovery

- Confirm local locking and retry transient failures up to three attempts; stop on missing permissions, cancellation, or observed lock. This never retries password entry.
- Lock the coordinator as well as followers before sleep; recheck the coordinator after wake and retain departure monitoring for a previously seen phone.
- Run presence and Bluetooth polling timers in common run-loop modes so opening menus does not pause monitoring.
- Show the latest local lock request result in the device list.

## 0.3.0 — First public source release

- Generalize multi-Mac pairing and discovery; remove development-specific network addresses.
- Add MIT licensing, third-party attribution, security guidance and contribution instructions.
- Publish reproducible build/check commands and macOS CI.
- Preserve the 0.2.9 credential and input implementation; existing installations are not modified by this source release.

## Private prototype history

- 0.2.9: paced Unicode input events, event-posting preflight and unlock-stage diagnostics. Real unlock confirmed after Keychain approval.
- 0.2.8: independent native password-entry dialog.
- 0.2.7: optional phone-return unlock, configurable RSSI threshold and departure timeout.
- Earlier prototypes: authenticated LAN control, accepted join requests, Bonjour/IP discovery, listener recovery and native dialog compatibility fixes.
