# Architecture

ScreenLink uses Swift, AppKit/SwiftUI, CoreBluetooth, Network, CryptoKit, Security and OpenDirectory on macOS. `ScreenLinkCore` contains protocol and policy code; `ScreenLink` provides the menu bar UI and platform integration. There are no external Swift package dependencies.

## Discovery and pairing

A coordinator advertises `_screenjoin._tcp` on TCP 45732. Followers browse Bonjour or use an explicitly configured address. Discovery probes exchange only the initial challenge and then close; they do not request membership or acquire a group key. No private deployment addresses are embedded.

Pairing uses ephemeral Curve25519 ECDH, a client commitment before host challenge, and an authenticated transcript. HKDF-SHA256 separates the encryption and six-digit comparison keys. Users compare the digits on both devices; the coordinator explicitly accepts while unlocked. AES-GCM protects the group grant, installation receipt and completion confirmation with purpose-specific associated data. The coordinator records the connection's remote address rather than trusting a claimed address. This custom protocol has not received an independent security audit.

Joining is separately switchable from control. Joining another group disables remote unlock on that member. The legacy pairing-code import remains available and contains the group secret; treat it as a credential.

## Control

TCP 45731 and `_screenlink._tcp` carry framed JSON messages. HMAC-SHA256 authenticates the original payload bytes with a shared 256-bit group key. A 15-second wall-clock tolerance, nonce replay cache, request/reply linkage, frame limits and timeouts constrain requests. All members share the same authority; a member cannot cryptographically prove that another member actually performed local biometric authentication. The payload is authenticated, not encrypted; passwords are never included.

The main queue confines network callbacks, model state and replay guards. Only the coordinator relays manual lock events. Presence leases expire after 12 seconds, so followers do not indefinitely suppress idle display sleep if communication stops.

## Presence

The coordinator observes a selected BLE peripheral UUID, optionally connecting and polling RSSI. The departure timer begins only after a valid signal. A configurable RSSI threshold and timeout determine absence; BLE names do not authenticate devices. Passive advertisements may renew presence but cannot trigger automatic unlock.

Return unlock requires fresh connected RSSI, above the departure threshold plus 5 dB when configured. It fires on the first qualifying sample or on return after the absence timeout. Short reconnects and continuous samples do not repeat. Pending phone authorization expires or is canceled when configuration, session or connection state changes. Authenticated peer identities are deduplicated before commands are sent.

## Local lock recovery

Coordinator lock requests verify the observed console state. Transient failures permit at most three attempts, with a one-second gap after each unsuccessful check; each posted shortcut is checked after two seconds. Missing input permissions stop immediately. A replaced request, settings change, shutdown, observed lock, or an authorized unlock invalidates queued work. For phone departure, renewed presence also prevents further attempts. Failures remain visible in the device list and recent events. Remote lock requests retain their existing single-attempt reply behavior.

Before system sleep, an enabled coordinator requests both local and peer locks. Sleep notifications cannot guarantee enough execution time to finish, so wake starts a fresh local confirmation cycle. Presence suspends without granting an awake lease; a previously seen phone receives a new configured absence grace period after wake. A fresh sample supersedes that deadline. A phone never seen remains unarmed. Presence and Bluetooth polling timers use common run-loop modes to continue during menu tracking.

These are bounded recovery measures, not a guarantee of locking when macOS refuses input. Password entry is never retried.

## Credentials and unlock

A native NSSecureTextField captures input without retaining it in SwiftUI state. OpenDirectory verifies the current user's password against `/Local/Default` once; only success permits writing the local Keychain. Passwords are neither trimmed nor normalized. Password and group key remain in separate accounts under `local.screenlink.credentials`.

Unlock checks the current console UID, lock state, Accessibility, event-posting permission, secure input and per-lock attempt state. It wakes the display, reads the password, constructs a complete event plan, then sends paced Unicode events with explicit modifier flags and one Return. Each stage rechecks authorization. Actual observed unlock determines success; event submission alone does not.

The secure-input flag is global, not proof of password-field focus. State can change between checking and posting. Keychain reads currently allow authorization UI and can wait until a user manually logs in; the installed build must be authorized locally before unattended use. No bypass, retry loop or automatic approval is implemented.

## Storage and defaults

Settings JSON contains preferences and device metadata, not secrets. The Keychain stores secrets separately. Network, automatic locking, remote unlock and idle prevention are default-off. Existing settings retain compatibility through optional fields; publishing this source does not migrate or rewrite users' existing installations.

See [SECURITY.md](../SECURITY.md), [validation](VALIDATION.md) and [third-party references](../THIRD_PARTY_NOTICES.md).

## Workstation coordination and sharing (0.4.0)

Feature-capable status replies advertise control capability 1. Workstation actions carry authenticated event IDs; older peers remain usable for manual basic control but receive no incompatible automatic commands. Followers report age-adjusted input activity to the coordinator. Automatic locks retain an intent through activity and pause, have short remote authorization leases, are revalidated after probes, and can be explicitly revoked. Pending local input still has at most three attempts. Observed remote unlocks suppress manual-unlock relay; busy attempts cannot clear another attempt's suppression. Input observation stores timestamps only and treats secure-input or permission uncertainty conservatively.

Pause state has a coordinator revision and bounded wall-clock deadline. Local persistence additionally uses the boot session ID and monotonic deadline to prevent restart/clock rollback extending a pause. Coordinator reboot/expiry publishes a new resume revision; follower reboot reacquires current state. Pauses never override manual/system locks.

Sharing uses TCP 45733 and `_screenshare._tcp`, separate from the bounded legacy control frames. A fresh X25519 exchange with group-key HMAC proofs binds both device IDs, nonces and public keys. HKDF derives independent directional AES-GCM keys from the authenticated transcript. Each record authenticates its direction-specific sequence and transcript; file names and contents are encrypted. Bounded handshake/transfer caches reject replays. This continues group-wide authority, not per-member hardware authentication, and is not an independently audited protocol.

Files stream in bounded chunks through a serial background queue; each connection handles one transfer, with size/concurrency/time limits. Receiver opens directory components without following symlinks, creates a private staging directory, writes through descriptors, checks full size and SHA-256, sets quarantine, and publishes without replacing existing files. Clipboard text/PNG uses the same encrypted transport with in-memory size bounds and access rechecks. Clipboard ordering uses a bounded hybrid logical timestamp and source ID; event ordering plus pasteboard change counts suppress loops and stale overwrites. Known confidential/transient/file types are skipped, not all possible secrets.

Platform input-monitoring reference: [Apple event monitoring](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html); secure-input behavior: [Apple TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html).
