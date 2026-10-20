import Foundation
import CoreGraphics

// Inspect synthetic events only; never post to the OS or read a real password.
var failures = 0
var checks = 0
func check(_ value: Bool, _ name: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(name)") }
}
func text(_ event: CGEvent) -> String {
    var count = 0
    event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
    var units = [UniChar](repeating: 0, count: count)
    units.withUnsafeMutableBufferPointer {
        event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress)
    }
    return String(decoding: units, as: UTF16.self)
}
func code(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.keyboardEventKeycode) }
let fixture = " Aé🔐e\u{301}! "
let plan = try PasswordInputEvents(password: fixture)
check(plan.selection.count == 2 && code(plan.selection[0]) == 0, "Selection uses paired Command-A")
check(plan.selection[0].flags == .maskCommand && plan.selection[1].flags.isEmpty,
      "Selection releases Command before typing")
check(plan.characters.count == fixture.unicodeScalars.count, "One pair per Unicode scalar")
let events = plan.characters.flatMap { $0 }
check(events.allSatisfy { code($0) == 49 && $0.flags.isEmpty }, "Unicode events use neutral key and no inherited modifiers")
check(plan.characters.allSatisfy { $0.count == 2 && $0[0].type == .keyDown && $0[1].type == .keyUp },
      "Every text key is released")
check(plan.characters.allSatisfy { Array(text($0[0]).utf16) == Array(text($0[1]).utf16) },
      "Down and up carry identical Unicode")
check(Array(plan.characters.map { text($0[0]) }.joined().utf8) == Array(fixture.utf8),
      "Text including spaces, surrogate pairs and combining marks is preserved exactly")
check(plan.submit.count == 2 && plan.submit.allSatisfy { code($0) == 36 && $0.flags.isEmpty },
      "Return submits once without modifiers")

func exercise(_ password: String, allowed: @escaping (Int) -> Bool) -> ([CGEvent], [Double], Result<Void, Error>?) {
    var posted: [CGEvent] = []
    var delays: [Double] = []
    var tasks: [() -> Void] = []
    var result: Result<Void, Error>?
    PasswordEventSender.send(password, allowed: { allowed(posted.count) },
        post: { posted.append($0) },
        schedule: { delay, action in delays.append(delay); tasks.append(action) },
        progress: { _ in }, completion: { result = $0 })
    var iterations = 0
    while !tasks.isEmpty && iterations < 1000 { iterations += 1; tasks.removeFirst()() }
    return (posted, delays, result)
}
let success = exercise(fixture, allowed: { _ in true })
if case .success? = success.2 { check(true, "Sender completes after submit") }
else { check(false, "Sender completes after submit") }
check(success.0.count == 4 + fixture.unicodeScalars.count * 2, "Only selection, text and one return are posted")
check(success.1.first == 0.12 && success.1.last == 0.12, "Selection and submit have explicit settling intervals")
check(success.1.filter { $0 == 0.01 }.count == fixture.unicodeScalars.count,
      "Text pairs are paced, never one synchronous batch")
for cutoff in [0, 2, 4] {
    let cancelled = exercise(fixture, allowed: { $0 < cutoff })
    if case .failure? = cancelled.2 {
        check(cancelled.0.count == cutoff && !cancelled.0.contains { code($0) == 36 },
              "Revoked authorization at event \(cutoff) stops without submit")
    } else { check(false, "Revoked authorization must fail") }
}
let empty = exercise("", allowed: { _ in true })
check(empty.0.isEmpty, "Empty secret never touches the input field")
let tooLong = exercise(String(repeating: "x", count: 257), allowed: { _ in true })
check(tooLong.0.isEmpty, "Oversized secret never touches the input field")
let longest = exercise(String(repeating: "x", count: 256), allowed: { _ in true })
check(longest.1.reduce(0, +) < 3, "Maximum supported password pacing fits network request budget")
print("\(checks) typing checks, \(failures) failures; no events posted to macOS")
exit(failures == 0 ? 0 : 1)
