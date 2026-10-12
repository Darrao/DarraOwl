import DarraOwlShared
import Foundation
import Testing

@Suite struct DurationTextTests {
    @Test(arguments: [
        ("90", 90 * 60.0),
        ("1h30", 5400),
        ("1 h 30", 5400),
        ("2h", 7200),
        ("2 H", 7200),
        ("1:45", 6300),
        ("45m", 2700),
        ("45 min", 2700),
        ("1h05min", 3900),
        ("0h30", 1800),
    ])
    func parsesValidInput(text: String, expected: TimeInterval) {
        #expect(DurationText.parse(text) == expected)
    }

    @Test(arguments: ["", "0", "abc", "1h75", "1:60", "-5", "h", "0h", "1:2:3", "12x"])
    func rejectsInvalidInput(text: String) {
        #expect(DurationText.parse(text) == nil)
    }

    @Test func threeFields() {
        #expect(DurationText.total(days: "", hours: "1", minutes: "30") == 5400)
        #expect(DurationText.total(days: "1", hours: "", minutes: "") == 86_400)
        #expect(DurationText.total(days: " ", hours: "0", minutes: "45") == 2700)
        #expect(DurationText.total(days: "", hours: "", minutes: "") == nil)
        #expect(DurationText.total(days: "0", hours: "0", minutes: "0") == nil)
        #expect(DurationText.total(days: "", hours: "-1", minutes: "") == nil)
        #expect(DurationText.total(days: "", hours: "1.5", minutes: "") == nil)
        #expect(DurationText.total(days: "", hours: "a", minutes: "") == nil)
    }

    @Test func shortFormat() {
        #expect(DurationText.short(1800) == "30 min")
        #expect(DurationText.short(3600) == "1 h")
        #expect(DurationText.short(5400) == "1 h 30")
        #expect(DurationText.short(3900) == "1 h 05")
    }

    @Test func countdownFormat() {
        #expect(DurationText.countdown(7170) == "1:59:30")
        #expect(DurationText.countdown(245) == "4:05")
        #expect(DurationText.countdown(8.2) == "0:09")
        #expect(DurationText.countdown(-3) == "0:00")
    }

    @Test func clockFormat() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(DurationText.clock(date, timeZone: TimeZone(identifier: "UTC")!) == "00:00")
    }
}

@Suite struct PowerSettingsTests {
    @Test func defaultsAreValid() throws {
        try PowerSettings.default.validate()
        #expect(PowerSettings.default.lowPowerFloor == 40)
        #expect(PowerSettings.default.endFloor == 15)
        #expect(PowerSettings.default.maxSessionDuration == 12 * 3600)
    }

    @Test func rejectsFloorsTooClose() {
        #expect(throws: PowerSettings.ValidationError.lowPowerFloorOutOfRange) {
            try PowerSettings(lowPowerFloor: 17, endFloor: 15).validate()
        }
    }

    @Test func rejectsEndFloorOutOfRange() {
        #expect(throws: PowerSettings.ValidationError.endFloorOutOfRange) {
            try PowerSettings(lowPowerFloor: 40, endFloor: 2).validate()
        }
    }

    @Test func rejectsCapAboveAbsoluteLimit() {
        #expect(throws: PowerSettings.ValidationError.maxDurationOutOfRange) {
            try PowerSettings(maxSessionDuration: 25 * 3600).validate()
        }
    }
}

@Suite struct SessionTests {
    @Test func remainingNeverNegative() {
        let start = Date(timeIntervalSince1970: 1000)
        let s = Session(startedAt: start, endsAt: start.addingTimeInterval(60), origin: .menuBar)
        #expect(s.remaining(at: start) == 60)
        #expect(s.remaining(at: start.addingTimeInterval(120)) == 0)
        #expect(s.isExpired(at: start.addingTimeInterval(60)))
    }
}

@Suite struct LidSettingsTests {
    @Test func defaultsPauseSlackWhatsAppDiscord() throws {
        let s = LidSettings()
        try s.validate()
        #expect(s.pausedApps == ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord"])
        #expect(s.darkenDisplay && s.mute && s.lowPower && s.pauseDocker)
    }

    @Test(arguments: ["com.microsoft.teams2", "us.zoom.xos", "us.zoom.ZoomCefHelper", "com.apple.FaceTime", "com.docker.docker", "com.darrao.darraowl.mac"])
    func meetingAndSystemAppsAreProtected(id: String) {
        #expect(throws: LidSettings.ValidationError.protectedApp(id)) {
            try LidSettings(pausedApps: [id]).validate()
        }
    }

    @Test(arguments: ["../../bin/sh", "rm -rf /", "com.slack;ls", "x", "com.é.app", "/Applications/Slack.app"])
    func malformedBundleIDsAreRefused(id: String) {
        #expect(throws: LidSettings.ValidationError.invalidBundleID(id)) {
            try LidSettings(pausedApps: [id]).validate()
        }
    }

    @Test func oldSettingsFileGetsLidDefaults() throws {
        let json = Data(#"{"lowPowerFloor":50,"endFloor":20,"maxSessionDuration":7200}"#.utf8)
        let s = try JSONDecoder().decode(PowerSettings.self, from: json)
        #expect(s.lowPowerFloor == 50)
        #expect(s.lid == LidSettings())
    }

    @Test func invalidLidMakesSettingsInvalid() {
        #expect(throws: PowerSettings.ValidationError.lid(.protectedApp("us.zoom.xos"))) {
            try PowerSettings(lid: LidSettings(pausedApps: ["us.zoom.xos"])).validate()
        }
    }
}

@Suite struct RemoteControlCommandTests {
    @Test func onlyStoppingThingsNeedsFaceID() {
        #expect(CommandKind.stopAgent(pid: 42).isSensitive)
        #expect(CommandKind.sleepNow.isSensitive)
        for kind: CommandKind in [.watchAgent(pid: 42), .startPresence(minutes: nil), .stopPresence, .displayOff,
                                  .lockScreen, .setMuted(true), .pauseApps, .resumeApps] {
            #expect(!kind.isSensitive, "\(kind)")
        }
    }

    @Test func presenceDurationsAreBounded() throws {
        try CommandKind.startPresence(minutes: nil).validateArguments()
        try CommandKind.startPresence(minutes: 60).validateArguments()
        try CommandKind.startPresence(minutes: 24 * 60).validateArguments()
        #expect(throws: CommandKind.ArgumentError.duration) { try CommandKind.startPresence(minutes: 0).validateArguments() }
        #expect(throws: CommandKind.ArgumentError.duration) { try CommandKind.startPresence(minutes: 24 * 60 + 1).validateArguments() }
        #expect(throws: CommandKind.ArgumentError.process) { try CommandKind.stopAgent(pid: 1).validateArguments() }
    }

    @Test func commandsSurviveTheWire() throws {
        let kinds: [CommandKind] = [.stopAgent(pid: 7), .startPresence(minutes: nil), .startPresence(minutes: 120), .setMuted(false), .lockScreen]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(CommandKind.self, from: data) == kind)
        }
    }

    @Test func stateFromAnOlderMacHasNoPresenceNorSound() throws {
        let state = MacState(macID: UUID(), macName: "Mac", updatedAt: Date(timeIntervalSince1970: 0), power: .awake, session: nil,
                             powerSnapshot: nil, lowPowerActive: false, pausedApps: [], network: nil, dockerPaused: false, settings: .default)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "presence")
        json.removeValue(forKey: "muted")
        let decoded = try JSONDecoder().decode(MacState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.presence == nil)
        #expect(decoded.muted == nil)
    }
}

@Suite struct WatchLinkTests {
    @Test func theWatchNeverAsksForFaceIDCommands() {
        #expect(!WatchLink.allowed(.sleepNow))
        #expect(!WatchLink.allowed(.stopContainer(id: "0123456789ab")))
        #expect(!WatchLink.allowed(.stopAgent(pid: 42)))
        #expect(WatchLink.allowed(.extendSession(minutes: 60)))
        #expect(WatchLink.allowed(.lockScreen))
        #expect(!WatchLink.allowed(.forgetThisDevice), "the watch never unpairs the iPhone")
    }

    @Test func messagesSurviveTheWire() throws {
        let request = WatchLink.Request.command(.startPresence(minutes: nil))
        #expect(try WatchLink.decode(WatchLink.Request.self, from: WatchLink.encode(request)) == request)
        let reply = WatchLink.Reply(ok: true, message: "fait", snapshot: .init(state: nil, macName: "Mac", presence: "En ligne", online: true, at: Date(timeIntervalSince1970: 0)))
        #expect(try WatchLink.decode(WatchLink.Reply.self, from: WatchLink.encode(reply)) == reply)
    }
}

@Suite struct EndpointsTests {
    @Test func onlyPlainPrivateAddressesArePlausible() {
        #expect(Endpoints(port: 52525, local: ["192.168.1.20", "10.0.0.2", "172.20.10.3"], tailscale: "100.101.1.2").isPlausible)
        #expect(!Endpoints(port: 52525, local: ["010.0.0.1"], tailscale: nil).isPlausible, "leading zero: octal to some parsers")
        #expect(!Endpoints(port: 52525, local: ["192.168.01.20"], tailscale: nil).isPlausible)
        #expect(Endpoints(port: 52525, local: ["10.0.0.0"], tailscale: nil).isPlausible)
        #expect(!Endpoints(port: 52525, local: ["8.8.8.8"], tailscale: nil).isPlausible)
    }

    @Test func aSessionSaysTourneOrTournent() {
        let one = WatchedProcess(pid: 2, name: "claude", project: "site", startSeconds: 1, startMicros: 0)
        let two = WatchedProcess(pid: 3, name: "npm", project: nil, startSeconds: 1, startMicros: 0)
        let t = Date(timeIntervalSince1970: 0)
        #expect(Session(startedAt: t, endsAt: t, origin: .cli, watching: [one]).whileWatchingText == "tant que claude · site tourne")
        #expect(Session(startedAt: t, endsAt: t, origin: .cli, watching: [one, two]).whileWatchingText == "tant que claude et npm tournent")
        #expect(Session(startedAt: t, endsAt: t, origin: .cli).whileWatchingText == nil)
    }
}

/// "+1 h" as the Mac applies it, which the phone shows before the answer.
@Suite struct ExtendedEndTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func addsToTheEndUnderTheCap() {
        let end = now.addingTimeInterval(1800)
        #expect(Session.extendedEnd(end, by: 3600, now: now, maxDuration: 8 * 3600) == end.addingTimeInterval(3600))
    }

    @Test func neverPastTheLongestSession() {
        let end = now.addingTimeInterval(6600)
        #expect(Session.extendedEnd(end, by: 3600, now: now, maxDuration: 7200) == now.addingTimeInterval(7200))
    }

    @Test func countsFromNowOnceEnded() {
        #expect(Session.extendedEnd(now.addingTimeInterval(-60), by: 1800, now: now, maxDuration: 7200) == now.addingTimeInterval(1800))
    }
}
