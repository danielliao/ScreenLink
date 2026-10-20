# Security

ScreenLink is experimental software for personally controlled Macs on a trusted LAN. Automatic actions are disabled by default.

## Boundaries

- All paired members share a control key and trust one another. A compromised member can issue authenticated control requests. Remove access by rotating the group key and pairing the intended members again.
- Pairing requires comparing the six-digit code on both devices before accepting. Names, IP addresses and BLE advertisements are not identity proofs.
- Control payloads are authenticated but not encrypted. The join grant is encrypted. Neither channel transports login passwords.
- Experimental unlock stores a locally verified password in the local Keychain and simulates keyboard input. Screen/secure-input checks cannot eliminate focus races. It is not Apple's Auto Unlock and does not support FileVault preboot or logged-out sessions.
- Phone presence does not establish who is carrying the phone. It may be unreliable or spoofed. Leaving a phone nearby can affect automatic behavior.
- Keychain access can require approval after an app update. Approve the intended installed application locally; do not send a password to the maintainer. A read awaiting authorization may keep an unlock request from completing.
- This protocol and application have not undergone independent security review. Use system-native authentication where stronger assurance is needed.

## Reporting

Use the repository's **Security → Advisories → Report a vulnerability** feature if available. If private reporting is unavailable, open an Issue requesting a private contact channel without including the vulnerability details, credentials or exploit data.

Do not post login passwords, Keychain exports, pairing codes, group keys, real settings files, device identifiers or unredacted diagnostic reports. Regular bug reports should include the app/macOS versions and a redacted description of the failed stage.
