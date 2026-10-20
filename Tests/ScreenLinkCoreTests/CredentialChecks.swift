import Foundation
import ScreenLinkCore

func runCredentialChecks() {
    var wrote = false
    let original = NSError(domain: "com.apple.OpenDirectory", code: 5000,
                           userInfo: [NSLocalizedDescriptionKey: "private-fixture-value"])
    do {
        try CredentialSetup.perform(verify: { throw original }, store: { wrote = true })
        check(false, "Verification failure is returned")
    } catch let error as CredentialSetupFailure {
        check(error.stage == .verification, "Verification failure has its own stage")
        check(error.code == 5000 && error.domain == original.domain, "System error identity is preserved")
        check(!error.localizedDescription.contains("private-fixture-value"), "Diagnostics omit arbitrary error userInfo")
    } catch { check(false, "Verification failure is classified") }
    check(!wrote, "Failed verification never writes the credential")

    var verified = false
    do {
        try CredentialSetup.perform(verify: { verified = true }, store: {
            throw NSError(domain: NSOSStatusErrorDomain, code: -25293)
        })
        check(false, "Storage failure is returned")
    } catch let error as CredentialSetupFailure {
        check(verified && error.stage == .keychain, "Keychain failure is distinct from rejected verification")
        check(error.code == -25293, "Keychain OSStatus is preserved")
    } catch { check(false, "Keychain failure is classified") }

    var operations: [String] = []
    do {
        try CredentialSetup.perform(verify: { operations.append("verify") }, store: { operations.append("store") })
        check(operations == ["verify", "store"], "Successful save verifies before writing exactly once")
    } catch { check(false, "Successful credential setup") }
}
