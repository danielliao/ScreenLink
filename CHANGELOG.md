# Changelog

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
