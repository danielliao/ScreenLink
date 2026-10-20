# Contributing

Please describe the problem and expected behavior before proposing large changes. Small focused fixes are welcome.

- Build on macOS with Swift 5.9+ and run `bash scripts/check.sh`.
- For dialog changes, run `bash scripts/check-prompts.sh` on an interactive desktop. `scripts/check-input.sh` provides an additional synthetic SwiftUI regression check.
- Keep Bluetooth, real lock/unlock and credential access out of automated tests. Use virtual inputs and actual loopback network tests where suitable.
- Keep automatic behavior default-off; preserve settings compatibility and per-device authorization.
- Never commit credentials, actual user settings, personal network addresses, signing certificates, crash reports or build backups.
- Document third-party code origins and preserve applicable licenses. See THIRD_PARTY_NOTICES.md before introducing a new dependency.

Contributions are submitted under this repository's MIT license. Include meaningful test evidence and distinguish automated checks from real-device results in pull requests.
