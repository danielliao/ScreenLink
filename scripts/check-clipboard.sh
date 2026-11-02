#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/screenlink-clipboard.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
cat > "$fixture_dir/check.swift" <<'SWIFT'
import AppKit
import Foundation

@main struct ClipboardFixtureChecks {
    @MainActor static func main() {
        var failures = 0
        var checks = 0
        func check(_ result: Bool, _ name: String) {
            checks += 1
            if !result { failures += 1; print("FAIL: \(name)") }
        }
        let board = NSPasteboard(name: NSPasteboard.Name("ScreenLink-Clipboard-Fixture-\(UUID())"))
        let peerBoard = NSPasteboard(name: NSPasteboard.Name("ScreenLink-Clipboard-Fixture-\(UUID())"))
        defer { board.releaseGlobally(); peerBoard.releaseGlobally() }
        func copy(_ text: String, to target: NSPasteboard) { target.clearContents(); target.setString(text, forType: .string) }
        copy("preexisting fixture", to: board)
        let sync = ClipboardSync(deviceID: UUID(), pasteboard: board)
        let peer = ClipboardSync(deviceID: UUID(), pasteboard: peerBoard)
        var outgoing: [(Data, String, String)] = []
        var incoming: [(Data, String, String)] = []
        sync.onCopy = { outgoing.append(($0, $1, $2)) }
        peer.onCopy = { incoming.append(($0, $1, $2)) }
        sync.tick(enabled: true, unlocked: true)
        peer.tick(enabled: true, unlocked: true)
        check(outgoing.isEmpty, "Enabling never reads or broadcasts old content")
        copy("new fixture", to: board)
        sync.tick(enabled: true, unlocked: true)
        guard let first = outgoing.first else { check(false, "New user copy is sent"); exit(1) }
        check(first.0 == Data("new fixture".utf8) && first.1 == "text", "Native text copies transmit UTF8")
        check(peer.receive(data: first.0, kind: first.1, event: first.2), "Peer applies new copy")
        check(peerBoard.string(forType: .string) == "new fixture", "Peer pasteboard contains received copy")
        peer.tick(enabled: true, unlocked: true)
        check(incoming.isEmpty, "Received content never echoes")
        check(!peer.receive(data: first.0, kind: first.1, event: first.2), "Duplicate not reapplied")
        copy("new fixture", to: board)
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == 1, "Identical recopy not rebroadcast")
        sync.tick(enabled: true, unlocked: false)
        check(!sync.receive(data: first.0, kind: first.1, event: first.2), "Locked receiver rejects clipboard")
        copy("locked fixture", to: board)
        sync.tick(enabled: true, unlocked: false)
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == 1, "Locked content not replayed after unlock")
        copy("remote fixture", to: peerBoard)
        peer.tick(enabled: true, unlocked: true)
        guard let remote = incoming.last else { check(false, "Peer new copy sent"); exit(1) }
        copy("local unsampled fixture", to: board)
        check(!sync.receive(data: remote.0, kind: remote.1, event: remote.2), "Incoming message preserves unsampled user copy")
        check(board.string(forType: .string) == "local unsampled fixture", "Unsampled copy remains on pasteboard")
        let sentBeforeSecret = outgoing.count
        board.clearContents()
        board.setString("secret fixture", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == sentBeforeSecret, "Concealed content not sent")
        board.clearContents()
        board.setString("file:///fixture-not-read", forType: .fileURL)
        board.setString("/fixture-not-read", forType: .string)
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == sentBeforeSecret, "File URL with text representation not shared")
        copy(String(repeating: "x", count: 1_048_577), to: board)
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == sentBeforeSecret, "Oversized text not truncated or sent")
        copy("after secret", to: board)
        sync.tick(enabled: true, unlocked: true)
        check(outgoing.count == sentBeforeSecret + 1, "Valid copy after blocked copy resumes")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        sync.tick(enabled: true, unlocked: true)
        guard let picture = outgoing.last else { exit(1) }
        check(picture.1 == "png", "Native image normalizes to PNG")
        check(peer.receive(data: picture.0, kind: picture.1, event: picture.2), "Peer accepts valid PNG")
        check(peerBoard.data(forType: .png) != nil, "Peer writes PNG clipboard type")
        copy("after png", to: board)
        sync.tick(enabled: true, unlocked: true)
        let freshEvent = outgoing.last!.2
        check(!peer.receive(data: Data(png.prefix(33)), kind: "png", event: freshEvent), "Truncated PNG rejected before clipboard replacement")
        check(peerBoard.data(forType: .png) != nil, "Malformed image leaves existing content intact")
        var corrupt = png
        if let idat = corrupt.range(of: Data("IDAT".utf8)) { corrupt[idat.upperBound] ^= 0xff }
        check(!peer.receive(data: corrupt, kind: "png", event: freshEvent), "Corrupt compressed pixels rejected before clipboard replacement")
        peer.tick(enabled: false, unlocked: true)
        check(!peer.receive(data: picture.0, kind: picture.1, event: picture.2), "Disabled receive rejected")
        print("\(checks) isolated clipboard checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
SWIFT
swiftc -emit-library -emit-module -module-name ScreenLinkCore Sources/ScreenLinkCore/ClipboardPolicy.swift -emit-module-path "$fixture_dir/ScreenLinkCore.swiftmodule" -o "$fixture_dir/libScreenLinkCore.dylib"
swiftc -parse-as-library -I "$fixture_dir" -L "$fixture_dir" -lScreenLinkCore Sources/ScreenLink/ClipboardSync.swift "$fixture_dir/check.swift" -o "$fixture_dir/checks"
DYLD_LIBRARY_PATH="$fixture_dir" "$fixture_dir/checks"
