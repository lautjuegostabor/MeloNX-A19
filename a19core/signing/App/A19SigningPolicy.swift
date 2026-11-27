// Validate the exact installed host/extension relationship. No signing mutation.
enum A19SigningPolicy {
    static func validPair(mainID:String,helperID:String,mainTeam:String,helperTeam:String)->Bool {
        !mainID.isEmpty && !mainTeam.isEmpty && mainTeam==helperTeam &&
        helperID.hasPrefix(mainID+".") && helperID != mainID
    }
    static func canRenewWhileIdle(engineActive:Bool,gameRunning:Bool)->Bool {
        !engineActive && !gameRunning
    }
}
