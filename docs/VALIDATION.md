# Validation and limitations

Automated checks validate implementation behavior, not Bluetooth reliability or macOS login-window acceptance.

## Automated checks

- `scripts/check.sh`: core checks, including actual loopback TCP exchange, authentication/replay, framing, pairing, listener rebinding, discovery, credential setup ordering, presence and return policies; 18 event-construction checks; app compilation and plist validation.
- `scripts/check-prompts.sh`: 15 AppKit dialog/input checks on an interactive desktop.
- `scripts/check-clipboard.sh`: isolated native clipboard tests using uniquely named fixture pasteboards.
- `scripts/check-input.sh`: 6 synthetic SwiftUI input checks on an interactive desktop.
- `scripts/build-app.sh`: arm64 release build, app bundle and signature verification.

Event tests inject a capture sink and scheduler; no events are posted to the system. UI tests use synthetic input and fixture windows, without real credentials, configuration, Bluetooth or lock/unlock actions. Headless CI runs the noninteractive checks only; UI checks require a local desktop.

## Field evidence before public release

Private testing included Apple Silicon Macs and macOS 15.0.1 / 26.2. Authenticated device-state queries worked after correcting system clock skew. Native password entry resolved a reported credential-saving failure. The user subsequently confirmed real unlock after completing local Keychain access authorization on the installed build. This does not establish successful unlock on every machine or system version.

An earlier macOS 15.0.1 crash in NSAlert's ImageIO/icon-loading path motivated code-built NSPanel dialogs. Finder startup of an unsigned/unnotarized download can be blocked by Gatekeeper even when direct executable startup works. Ad-hoc signature verification is not Apple notarization.

## Still requires device acceptance

- Each target's lock, manual unlock request and observed unlocked desktop.
- Phone visibility while its screen is off, in a pocket, and after leaving/returning; three-device automatic return unlock.
- Sleep, lid closure, network loss, process termination and permission changes.
- Current macOS updates, different input sources, fast user switching and Keychain authorization changes.

0.3.0 removes development-specific addresses and publishes generalized documentation; the input/credential path remains the field-tested 0.2.9 implementation. No broad compatibility guarantee or independent protocol audit is claimed.

## Public-source preparation check

On 2026-10-20, 117 core checks, 18 input-event checks and 15 native prompt checks passed locally. Debug and arm64 Release builds succeeded. The extracted 0.3.0 archive passed deep/strict signature verification and contains the project license and attribution files. The 49-file source publication set was checked for local user paths, deployment addresses and common credential patterns, with no findings; this is a bounded scan, not a guarantee that every possible secret pattern is detectable. Existing installed 0.2.9 was left unchanged.

## 0.3.1 lock recovery checks — 2026-10-28

135 core checks, 18 input-event checks and 15 native prompt checks passed locally (168 total). The 18 new recovery checks exercise the production retry controller, suspended presence policy and common-mode timer with simulated state/time and no system input. Three isolated regression mutations (single-attempt locking, discarded wake deadline, default-mode timer) each fail the targeted checks; the fixed implementation passes. Debug build and plist validation passed.

The coordinator sleep-notification wiring was reviewed in source. Automated checks do not suspend the host, lock the desktop, access real credentials or operate the user's other Macs. Real phone-departure locking on the coordinator and followers, wake with the phone absent, and menu-open detection still require device acceptance. The installed application is not replaced by packaging.

## 0.4.0 workstation sharing — 2026-11-02

New automated coverage exercises activity/pause deadlines, unlock transition suppression, authenticated workstation commands, old Settings compatibility, encrypted ephemeral sharing sessions, bounded framing, replay/tampering, no-clobber file publication, staging-entry replacement, quarantine, partial cleanup, cancellation, invalid digests and real local TCP exchanges. Clipboard policy and isolated AppKit tests cover enable/unlock baselines, simultaneous event ordering, unsampled local copies, sensitive/file types, PNG validation and duplicate suppression. Regression variants for authenticated hello replay (including JSON reformatting), staging-entry substitution, and persisted-pause extension were observed failing before corrections.

The default checks do not touch the user's actual clipboard, configuration, Keychain or other Macs. Separate native clipboard checks use unique fixture pasteboards and synthetic data. Real multi-Mac manual-unlock fan-out, typing/mouse protection, group pause acknowledgements, drag-and-drop, clipboard permission behavior and network/firewall handling still require installation and device acceptance. A 2 GiB limit is tested with sparse-file metadata; this is not a sustained 2 GiB transfer benchmark. Actual disk exhaustion/quota failures and every macOS version have not been exercised. Source inspection and compilation cover UI wiring; a full live three-device UI acceptance run is not claimed.

Local 0.4.0 verification: 305 core checks, 18 input-event checks, 15 native prompt checks, 22 isolated native clipboard checks and 6 synthetic input checks passed (366 total). Actual fixed-port sharing restarts and a rapid eight-reconfiguration sequence verify listener cancellation/rebinding; stopping the service mid-transfer aborts both ends and cleans staging. Debug/Release compilation and extracted-archive signature checks are required for the distributed bundle. These results do not establish the field acceptance scenarios above.
