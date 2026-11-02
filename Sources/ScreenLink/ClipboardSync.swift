import AppKit
import CryptoKit
import ImageIO
import ScreenLinkCore

/// Call only on the main queue. No content is retained after
/// a tick; only its digest, change count and ordering metadata survive.
final class ClipboardSync {
    var onCopy: ((Data, String, String) -> Void)?
    private let pasteboard: NSPasteboard
    private var policy: ClipboardPolicy
    private var active = false
    private var observedCount = 0

    init(deviceID: UUID, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        policy = ClipboardPolicy(deviceID: deviceID)
    }

    func tick(enabled: Bool, unlocked: Bool) {
        let next = enabled && unlocked
        if next != active {
            active = next
            // Read only the metadata when entering an unlocked access interval.
            if next { observedCount = pasteboard.changeCount }
            policy.setAccess(enabled: enabled, unlocked: unlocked, changeCount: observedCount, now: now)
            return
        }
        guard active else { return }
        sampleLocal()
    }

    @discardableResult
    func receive(data: Data, kind: String, event: String) -> Bool {
        guard active, ClipboardPolicy.accepts(data: data, kind: kind),
              kind != "png" || Self.validImage(data),
              let parsed = policy.prepare(event: event, now: now) else { return false }
        // This observation advances the logical clock first: a user copy made
        // since our last tick takes precedence even with skewed wall clocks.
        sampleLocal()
        guard pasteboard.changeCount == observedCount else { return false }
        var candidate = policy
        guard candidate.accept(event: parsed, fingerprint: Self.digest(data, kind: kind)) else {
            policy = candidate
            return false
        }
        pasteboard.clearContents()
        let written = pasteboard.setData(data, forType: kind == "text" ? .string : .png)
        observedCount = pasteboard.changeCount
        guard written else {
            policy.markWritten(changeCount: observedCount)
            return false
        }
        policy = candidate
        policy.markWritten(changeCount: observedCount)
        return true
    }

    private var now: UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    }

    private func sampleLocal() {
        guard active else { return }
        let count = pasteboard.changeCount
        guard count != observedCount else { return }
        let payload = readPayload()
        // A changing pasteboard is sampled again next tick, never partially sent.
        guard pasteboard.changeCount == count else { return }
        observedCount = count
        let fingerprint = payload.map { Self.digest($0.data, kind: $0.kind) }
        let event = policy.localChange(changeCount: count, fingerprint: fingerprint, now: now)
        if let event, let payload { onCopy?(payload.data, payload.kind, event.encoded) }
    }

    private func readPayload() -> (data: Data, kind: String)? {
        let types = pasteboard.types ?? []
        guard !ClipboardPolicy.blocks(types: types.map(\.rawValue)) else { return nil }
        // Inspect every item's markers, including a marker on a different item.
        if pasteboard.pasteboardItems?.contains(where: {
            ClipboardPolicy.blocks(types: $0.types.map(\.rawValue))
        }) == true { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff] where types.contains(type) {
            guard let original = pasteboard.data(forType: type), original.count <= 10_485_760,
                  Self.validImage(original), let bitmap = NSBitmapImageRep(data: original),
                  let png = bitmap.representation(using: .png, properties: [:]),
                  ClipboardPolicy.accepts(data: png, kind: "png") else { return nil }
            return (png, "png")
        }
        guard types.contains(.string), let data = pasteboard.data(forType: .string),
              ClipboardPolicy.accepts(data: data, kind: "text") else { return nil }
        return (data, "text")
    }

    private static func digest(_ data: Data, kind: String) -> String {
        kind + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validImage(_ data: Data) -> Bool {
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), !validPNGChunks(data) { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else { return false }
        return true
    }

    // ImageIO tolerates damaged PNG chunks. Verify their checksums before
    // allowing remote bytes to replace the user's clipboard.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func validPNGChunks(_ data: Data) -> Bool {
        func word(_ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
        var offset = 8
        var sawPixels = false
        while offset <= data.count - 12 {
            let length = Int(word(offset))
            guard length <= data.count - offset - 12 else { return false }
            let type = word(offset + 4)
            if offset == 8, type != 0x49484452 || length != 13 { return false }
            var crc: UInt32 = 0xffffffff
            for index in (offset + 4)..<(offset + 8 + length) {
                crc = crcTable[Int((crc ^ UInt32(data[index])) & 0xff)] ^ (crc >> 8)
            }
            guard (crc ^ 0xffffffff) == word(offset + 8 + length) else { return false }
            offset += length + 12
            if type == 0x49444154 { sawPixels = true }
            if type == 0x49454e44 { return length == 0 && sawPixels && offset == data.count }
        }
        return false
    }

}
