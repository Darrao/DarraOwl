import DarraOwlCore
import DarraOwlShared
@testable import DarraOwlXPC
import Foundation
import Testing

@Suite struct CodeRequirementTests {
    @Test func validTeamIDBuildsRequirements() {
        let client = CodeRequirements.client(teamID: "S3YD258U2R")
        #expect(client == "anchor apple generic and certificate leaf[subject.OU] = \"S3YD258U2R\" and (identifier \"com.darrao.darraowl.mac\" or identifier \"com.darrao.darraowl.mac.cli\")")
        #expect(CodeRequirements.helper(teamID: "S3YD258U2R")?.hasSuffix("identifier \"com.darrao.darraowl.mac.helper\"") == true)
    }

    @Test(arguments: ["", "s3yd258u2r", "S3YD258U2", "S3YD258U2R1", "S3YD258U\"R", "S3YD 58U2R"])
    func invalidTeamIDIsRefused(team: String) {
        #expect(CodeRequirements.client(teamID: team) == nil)
        #expect(CodeRequirements.helper(teamID: team) == nil)
    }
}

@Suite struct HelperCodingTests {
    @Test(arguments: [
        HelperRequest.status,
        .start(seconds: 3600, origin: .menuBar),
        .extend(seconds: 1800),
        .stop(reason: .userStopped),
        .updateSettings(PowerSettings(lowPowerFloor: 50, endFloor: 20, maxSessionDuration: 6 * 3600)),
        .prepareUninstall,
        .restartIfIdle,
    ])
    func requestRoundTrip(request: HelperRequest) throws {
        let data = try HelperCoding.encode(request)
        #expect(try HelperCoding.decode(HelperRequest.self, from: data) == request)
    }

    @Test func unknownRequestIsRejected() {
        let data = Data(#"{"runShell":{"command":"rm -rf /"}}"#.utf8)
        #expect(throws: (any Error).self) { _ = try HelperCoding.decode(HelperRequest.self, from: data) }
    }
}
