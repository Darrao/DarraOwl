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
