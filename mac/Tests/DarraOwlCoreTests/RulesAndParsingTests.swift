@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@Suite struct FloorRulesTests {
    let settings = PowerSettings.default

    func decide(_ battery: BatteryStatus, ac: Bool = false, thermal: ThermalLevel = .nominal, misses: Int = 0) -> FloorDecision {
        FloorRules.decide(power: PowerSnapshot(battery: battery, onExternalPower: ac, thermal: thermal), unreadableReads: misses, settings: settings)
    }

    @Test func comfortableBatteryWantsNothing() {
        #expect(decide(.percent(80)) == FloorDecision())
    }

    @Test func underLowPowerFloorWantsLowPower() {
        #expect(decide(.percent(39)) == FloorDecision(wantsLowPower: true))
        #expect(decide(.percent(40)) == FloorDecision())
    }

    @Test func underEndFloorEnds() {
        #expect(decide(.percent(14)).endReason == .batteryLow)
        #expect(decide(.percent(15)).endReason == nil)
    }

    @Test func chargerDisablesBatteryRules() {
        #expect(decide(.percent(5), ac: true) == FloorDecision())
    }

    @Test func heat() {
        #expect(decide(.percent(80), thermal: .serious) == FloorDecision(wantsLowPower: true))
        #expect(decide(.percent(80), ac: true, thermal: .critical).endReason == .thermalCritical)
    }

    @Test func unreadableBattery() {
        #expect(decide(.unreadable, misses: 1).endReason == nil)
        #expect(decide(.unreadable, misses: 2).endReason == .batteryUnreadable)
        #expect(decide(.unreadable, ac: true, misses: 5).endReason == nil)
    }

    @Test func desktopHasNoBatteryRules() {
        #expect(decide(.none) == FloorDecision())
    }

    @Test func startRefusalForUnreadableBatteryOnBattery() {
        let power = PowerSnapshot(battery: .unreadable, onExternalPower: false, thermal: .nominal)
        #expect(FloorRules.startRefusal(power: power, settings: settings) == .batteryUnreadable)
    }
}

@Suite struct PmsetParserTests {
    static let custom = """
    Battery Power:
     Sleep On Power Button 1
     lowpowermode         1
     standby              1
    AC Power:
     Sleep On Power Button 1
     lowpowermode         0
     standby              1
    """

    static let get = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     lowpowermode         1
    """

    @Test func readsEachProfile() {
        let modes = PmsetParser.lowPowerModes(fromCustom: Self.custom)
        #expect(modes.battery == true)
        #expect(modes.ac == false)
    }

    @Test func desktopHasNoBatteryProfile() {
        let modes = PmsetParser.lowPowerModes(fromCustom: "AC Power:\n lowpowermode         1\n")
        #expect(modes.battery == nil)
        #expect(modes.ac == true)
    }

    @Test func readsSleepDisabled() {
        #expect(PmsetParser.sleepDisabled(fromGet: Self.get) == true)
        #expect(PmsetParser.sleepDisabled(fromGet: " SleepDisabled\t\t0\n") == false)
        #expect(PmsetParser.sleepDisabled(fromGet: "Currently in use:\n sleep 1\n") == nil)
    }
}

@Suite struct JSONFileStoreTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "darraowl-tests-\(UUID().uuidString)/state")
    }

    @Test func roundTripWithOwnerOnlyPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = JSONFileStore<Journal>(directory: dir, fileName: "journal.json")
        #expect(try store.load() == nil)

        var journal = Journal()
        journal.session = Session(startedAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_003_600), origin: .phone)
        journal.sleep = SleepEntry(previouslyDisabled: false)
        try store.save(journal)

        #expect(try store.load() == journal)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func garbageIsUnreadableAndQuarantined() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = JSONFileStore<Journal>(directory: dir, fileName: "journal.json")
        try Data("{not json".utf8).write(to: store.url)

        #expect(throws: StoreError.self) { _ = try store.load() }
        let moved = try store.quarantine()
        #expect(moved != nil)
        #expect(FileManager.default.fileExists(atPath: moved!))
        #expect(try store.load() == nil)
    }
}
