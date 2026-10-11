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
