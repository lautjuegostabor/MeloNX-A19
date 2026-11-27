import Foundation
// Pure UI policy shared by the coordinator, views and regression tests.
struct SigningControls {
    let configured: Bool
    let automatic: Bool
    let running: Bool
    let setupActive: Bool
    let validExpiry: Bool
    var idle: Bool { !running && !setupActive }
    var canToggleAutomatic: Bool { !running && (automatic || (idle && configured && validExpiry)) }
    var canRenew: Bool { idle && configured && validExpiry }
    var canImport: Bool { idle }
    var canManageSession: Bool { idle && configured }
    var canBackup: Bool { canRenew }
    func canStartSetup(setupRunning: Bool) -> Bool { !running && !setupRunning }
    static func normalizedAutomatic(_ requested: Bool, sessionDefinitelyMissing: Bool) -> Bool {
        requested && !sessionDefinitelyMissing
    }
}

// No elapsed-time gate. User consent and an idle verified setup are the only
// local prerequisites (along with well-formed input accepted by the FFI).
struct AuthenticationControls {
    let verified: Bool
    let running: Bool
    let signingRunning: Bool
    let setupActive: Bool
    let pendingSave: Bool
    var canEnterCredentials: Bool { verified && !running && !signingRunning && setupActive && !pendingSave }
    static func validCredentials(email: String, password: String) -> Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty &&
        email.utf8.count <= 320 && password.utf8.count <= 1024 &&
        !email.utf8.contains(0) && !password.utf8.contains(0)
    }
    func submit(email: String, password: String, consent: Bool, start: () -> Bool) -> Bool {
        guard canEnterCredentials, consent, Self.validCredentials(email: email, password: password) else { return false }
        return start()
    }
    static func validCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }
}
