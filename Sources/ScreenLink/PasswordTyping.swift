import Foundation
import CoreGraphics

enum PasswordTypingError: Error {
    case invalidLength, eventCreationFailed, authorizationChanged
}

struct PasswordInputEvents {
    let selection: [CGEvent]
    let characters: [[CGEvent]]
    let submit: [CGEvent]

    init(password: String) throws {
        guard !password.isEmpty, password.utf16.count <= 256 else { throw PasswordTypingError.invalidLength }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw PasswordTypingError.eventCreationFailed
        }
        func pair(_ code: CGKeyCode, text: String? = nil, flags: CGEventFlags = []) throws -> [CGEvent] {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw PasswordTypingError.eventCreationFailed
            }
            // Never inherit physical keyboard or previous synthetic Command flags.
            down.flags = flags
            up.flags = []
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { pointer in
                    down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress!)
                }
            }
            return [down, up]
        }
        selection = try pair(0, flags: .maskCommand)
        // Space is the neutral carrier used by the reference implementation.
        // One scalar per pair avoids multi-character event handling differences
        // and never splits UTF-16 surrogate pairs.
        characters = try password.unicodeScalars.map { try pair(49, text: String($0)) }
        submit = try pair(36)
    }
}

enum PasswordEventSender {
    enum Progress { case selected, textPosted, submitted }
    static func send(_ password: String, allowed: @escaping () -> Bool,
                     post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                     schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
                         DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                     },
                     progress: @escaping (Progress) -> Void,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        let events: PasswordInputEvents
        do { events = try PasswordInputEvents(password: password) }
        catch { completion(.failure(error)); return }
        func emit(_ pair: [CGEvent]) {
            for event in pair {
                event.timestamp = DispatchTime.now().uptimeNanoseconds
                post(event)
            }
        }
        func write(_ index: Int) {
            guard allowed() else { completion(.failure(PasswordTypingError.authorizationChanged)); return }
            guard index < events.characters.count else {
                progress(.textPosted)
                schedule(0.12) {
                    guard allowed() else { completion(.failure(PasswordTypingError.authorizationChanged)); return }
                    emit(events.submit)
                    progress(.submitted)
                    completion(.success(()))
                }
                return
            }
            emit(events.characters[index])
            schedule(0.01) { write(index + 1) }
        }
        guard allowed() else { completion(.failure(PasswordTypingError.authorizationChanged)); return }
        emit(events.selection)
        progress(.selected)
        schedule(0.12) { write(0) }
    }
}
