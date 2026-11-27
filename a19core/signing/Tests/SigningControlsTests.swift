@main struct SigningControlsTests {
    static func main() {
        for configured in [false, true] {
            for automatic in [false, true] {
                for running in [false, true] {
                    for setup in [false, true] {
                        for valid in [false, true] {
                            let p = SigningControls(configured: configured, automatic: automatic,
                                running: running, setupActive: setup, validExpiry: valid)
                            precondition(p.canToggleAutomatic == (!running && (automatic || (configured && !setup && valid))))
                            precondition(p.canRenew == (configured && !running && !setup && valid))
                            precondition(p.canImport == (!running && !setup))
                            precondition(p.canManageSession == (configured && !running && !setup))
                            precondition(p.canBackup == p.canRenew)
                            precondition(p.canStartSetup(setupRunning: false) == !running)
                            precondition(!p.canStartSetup(setupRunning: true))
                        }
                    }
                }
            }
        }
        let stranded = SigningControls(configured: false, automatic: true, running: false, setupActive: false, validExpiry: true)
        precondition(stranded.canToggleAutomatic && stranded.canStartSetup(setupRunning: false))
        precondition(!stranded.canRenew)
        precondition(!SigningControls.normalizedAutomatic(true, sessionDefinitelyMissing: true))
        precondition(SigningControls.normalizedAutomatic(true, sessionDefinitelyMissing: false))
        // No clock or prior-attempt timestamp participates in eligibility.
        let idle = AuthenticationControls(verified: true, running: false, signingRunning: false, setupActive: true, pendingSave: false)
        var calls = 0
        func reject() -> Bool { calls += 1; return false }
        func accept() -> Bool { calls += 1; return true }
        precondition(!idle.submit(email: "a@example.test", password: "test", consent: false, start: accept))
        precondition(calls == 0)
        precondition(!idle.submit(email: "a@example.test", password: "test", consent: true, start: reject))
        precondition(calls == 1)
        precondition(idle.submit(email: "a@example.test", password: "test", consent: true, start: accept))
        precondition(calls == 2) // immediate explicit retry after internal rejection
        for verified in [false,true] {
            for running in [false,true] {
                for signingRunning in [false,true] {
                    for setupActive in [false,true] {
                        for pendingSave in [false,true] {
                            let state = AuthenticationControls(verified: verified, running: running, signingRunning: signingRunning, setupActive: setupActive, pendingSave: pendingSave)
                            let expected = verified && !running && !signingRunning && setupActive && !pendingSave
                            let before = calls
                            precondition(state.submit(email: "a@example.test", password: "test", consent: true, start: accept) == expected)
                            precondition(calls == before + (expected ? 1 : 0))
                        }
                    }
                }
            }
        }
        precondition(!AuthenticationControls.validCredentials(email: "  ", password: "test"))
        precondition(!AuthenticationControls.validCredentials(email: "a\u{0000}b", password: "test"))
        precondition(!AuthenticationControls.validCredentials(email: "a@example.test", password: String(repeating: "x", count: 1025)))
        precondition(AuthenticationControls.validCode("012345"))
        precondition(!AuthenticationControls.validCode("12345"))
        precondition(!AuthenticationControls.validCode("１２３４５６"))
        precondition(A19SigningPolicy.validPair(mainID:"com.stossy11.MeloNX",helperID:"com.stossy11.MeloNX.JITHelper",mainTeam:"TEAM",helperTeam:"TEAM"))
        precondition(!A19SigningPolicy.validPair(mainID:"com.stossy11.MeloNX",helperID:"com.other.app.JITHelper",mainTeam:"TEAM",helperTeam:"TEAM"))
        precondition(!A19SigningPolicy.validPair(mainID:"a",helperID:"a.JITHelper",mainTeam:"TEAM",helperTeam:"OTHER"))
        for engine in [false,true] { for game in [false,true] {
            precondition(A19SigningPolicy.canRenewWhileIdle(engineActive:engine,gameRunning:game)==(!engine && !game))
        } }
        print("Signing and authentication control matrices passed (64 states), idle gate and JIT helper identity passed")
    }
}
