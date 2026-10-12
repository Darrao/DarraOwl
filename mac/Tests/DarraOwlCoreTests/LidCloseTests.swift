@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@Suite struct FreezeTests {
    func target(_ pid: Int32, start: Int64) -> FreezeTarget {
        FreezeTarget(pid: pid, identity: ProcessIdentity(startSeconds: start, startMicros: 7, bootSession: FakeProcesses.boot))
    }

    func started() async throws -> Harness {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.events.clear()
        return h
    }

    @Test func journalIsWrittenBeforeSIGSTOP() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        h.processes.set(101, FakeProcesses.state(start: 2))
        let slack = FreezeGroup(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", targets: [target(100, start: 1), target(101, start: 2)])

        let status = try await h.engine.freeze([slack], requesterUID: 501)

        #expect(h.events.all == ["save journal", "SIGSTOP 100", "SIGSTOP 101"])
        #expect(status.frozen.map(\.pid) == [100, 101])
        #expect(h.processes.state(100)?.stopped == true)
    }

    @Test func refusesOtherUsersRootStoppedAndChangedProcesses() async throws {
        let h = try await started()
        h.processes.set(200, FakeProcesses.state(uid: 0, start: 1))      // root
        h.processes.set(201, FakeProcesses.state(uid: 502, start: 1))    // another user
        h.processes.set(202, FakeProcesses.state(start: 1, stopped: true)) // stopped by someone else
        h.processes.set(203, FakeProcesses.state(start: 99))             // pid reused
        let group = FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [
            target(200, start: 1), target(201, start: 1), target(202, start: 1), target(203, start: 1), target(204, start: 1),
        ])

        let status = try await h.engine.freeze([group], requesterUID: 501)

        #expect(status.frozen.isEmpty)
        #expect(h.events.all.isEmpty)
    }

    @Test func refusesProtectedApps() async throws {
        let h = try await started()
        h.processes.set(300, FakeProcesses.state(start: 1))
        let teams = FreezeGroup(bundleID: "com.microsoft.teams2", name: "Teams", targets: [target(300, start: 1)])
        let status = try await h.engine.freeze([teams], requesterUID: 501)
        #expect(status.frozen.isEmpty)
        #expect(h.processes.state(300)?.stopped == false)
    }

    @Test func dockerIsAllowed() async throws {
        let h = try await started()
        h.processes.set(400, FakeProcesses.state(start: 1))
        let docker = FreezeGroup(bundleID: PausePolicy.dockerBundleID, name: "Docker Desktop", targets: [target(400, start: 1)])
        let status = try await h.engine.freeze([docker], requesterUID: 501)
        #expect(status.frozen.count == 1)
    }

    @Test func nothingIsPausedWithoutSession() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.processes.set(100, FakeProcesses.state(start: 1))
        await #expect(throws: EngineError.noActiveSession) {
            _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)])], requesterUID: 501)
        }
    }

    @Test func journalFailurePausesNothing() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        h.journal.update { $0.failWrites = true }
        await #expect(throws: EngineError.self) {
            _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)])], requesterUID: 501)
        }
        #expect(h.processes.state(100)?.stopped == false)
    }

    @Test func resumeOnLidOpen() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)])], requesterUID: 501)
        let status = await h.engine.resume()
        #expect(status.frozen.isEmpty)
        #expect(h.processes.state(100)?.stopped == false)
        #expect(status.session != nil)
    }

    @Test func resumeOneAppOnly() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        h.processes.set(400, FakeProcesses.state(start: 1))
        _ = try await h.engine.freeze([
            FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)]),
            FreezeGroup(bundleID: PausePolicy.dockerBundleID, name: "Docker Desktop", targets: [target(400, start: 1)]),
        ], requesterUID: 501)
        let status = await h.engine.resume(onlyBundleID: PausePolicy.dockerBundleID)
        #expect(status.frozen.map(\.pid) == [100])
        #expect(h.processes.state(400)?.stopped == false)
    }

    @Test func sessionEndResumes() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)])], requesterUID: 501)
        h.clock.advance(3600)
        let status = await h.engine.evaluate()
        #expect(status.session == nil)
        #expect(status.frozen.isEmpty)
        #expect(h.processes.state(100)?.stopped == false)
    }

    @Test func reusedPidIsNotSignaledAtResume() async throws {
        let h = try await started()
        h.processes.set(100, FakeProcesses.state(start: 1))
        _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.hnc.Discord", name: "Discord", targets: [target(100, start: 1)])], requesterUID: 501)
        // Discord exited; another process now has pid 100 (and is stopped by someone else).
        h.processes.set(100, FakeProcesses.state(start: 50, stopped: true))
        h.events.clear()
        let status = await h.engine.resume()
        #expect(status.frozen.isEmpty)
        #expect(h.events.all.allSatisfy { !$0.hasPrefix("SIGCONT") })
    }

    @Test func frozenFromEarlierBootIsDroppedAtReconcile() async {
        var journal = Journal()
        journal.frozen = [FrozenProcess(pid: 100, identity: ProcessIdentity(startSeconds: 1, startMicros: 7, bootSession: "BOOT-OLD"), bundleID: "com.hnc.Discord", name: "Discord")]
        let h = Harness(journal: journal)
        h.processes.set(100, FakeProcesses.state(start: 1, stopped: true))
        let status = await h.engine.reconcile()
        #expect(status.frozen.isEmpty)
        #expect(h.processes.state(100)?.stopped == true, "not ours: identity differs")
    }
}

@Suite struct UserChangesTests {
    @Test func recordKeepsFirstSavedValues() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        let speakers = AudioEntry(deviceUID: "spk", name: "Haut-parleurs", volume: 0.6, muted: false)
        _ = try await h.engine.recordUserChanges(UserChanges(displayBrightness: 0.8, keyboardBrightness: 0.5, audio: [speakers]))
        // A second close while still closed would read 0 and a muted device.
        let status = try await h.engine.recordUserChanges(UserChanges(displayBrightness: 0, audio: [AudioEntry(deviceUID: "spk", name: nil, volume: 0, muted: true)]))
        #expect(status.userChanges.displayBrightness == 0.8)
        #expect(status.userChanges.audio == [speakers])
        #expect(h.journal.value?.user.displayBrightness == 0.8)
    }

    @Test func clearRemovesOnlyWhatWasRestored() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        _ = try await h.engine.recordUserChanges(UserChanges(displayBrightness: 0.8, audio: [
            AudioEntry(deviceUID: "a", name: nil, volume: 0.5, muted: false),
            AudioEntry(deviceUID: "b", name: nil, volume: 0.3, muted: false),
        ]))
        let status = await h.engine.clearUserChanges([.display, .audio(deviceUID: "a")])
        #expect(status.userChanges.displayBrightness == nil)
        #expect(status.userChanges.audio.map(\.deviceUID) == ["b"])
    }

    @Test func userChangesOutliveSessionUntilAppRestores() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        _ = try await h.engine.recordUserChanges(UserChanges(displayBrightness: 0.8))
        let status = try await h.engine.stop(reason: .userStopped)
        #expect(status.userChanges.displayBrightness == 0.8)
        #expect(h.journal.value?.isClean == true, "the helper has nothing left to undo itself")
    }

    @Test func recordNeedsSession() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        await #expect(throws: EngineError.noActiveSession) {
            _ = try await h.engine.recordUserChanges(UserChanges(displayBrightness: 0.8))
        }
    }

    @Test func oldJournalDecodes() throws {
        let json = Data(#"{"version":1,"sleep":{"previouslyDisabled":false}}"#.utf8)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let j = try d.decode(Journal.self, from: json)
        #expect(j.frozen.isEmpty && j.user.isEmpty && j.sleep != nil)
    }
}

@Suite struct LidLowPowerTests {
    @Test func closedLidWantsLowPowerEvenOnCharger() {
        let power = PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .nominal, lidClosed: true)
        #expect(FloorRules.decide(power: power, unreadableReads: 0, settings: .default).wantsLowPower)
        var off = PowerSettings.default
        off.lid.lowPower = false
        #expect(!FloorRules.decide(power: power, unreadableReads: 0, settings: off).wantsLowPower)
    }

    func lid(_ closed: Bool) -> PowerSnapshot {
        PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .nominal, lidClosed: closed)
    }

    @Test func openingTheLidRestoresLowPower() async throws {
        let h = Harness()
        h.source.set(lid(false))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(lid(true))
        #expect(await !h.engine.evaluate().lowPowerHeld, "not settled yet")
        h.clock.advance(SessionEngine.lidSettle)
        #expect(await h.engine.evaluate().lowPowerHeld)
        h.source.set(lid(false))
        _ = await h.engine.evaluate()
        h.clock.advance(SessionEngine.lidSettle)
        #expect(await !h.engine.evaluate().lowPowerHeld)
        #expect(h.power.current.lowPowerOnAC == false)
    }

    /// The night of 2026-10-12: closed, open, closed, open, closed in 8 s.
    @Test func aBouncingLidIsIgnoredUntilItSettles() async throws {
        let h = Harness()
        h.source.set(lid(false))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.events.clear()

        for (closed, after) in [(true, 1.3), (false, 2.4), (true, 3.2), (false, 1.2)] as [(Bool, TimeInterval)] {
            h.source.set(lid(closed))
            let status = await h.engine.evaluate()
            #expect(status.power?.lidClosed == false, "the open lid still counts")
            #expect(!status.lowPowerHeld)
            h.clock.advance(after)
        }
        #expect(!h.events.all.contains { $0.hasPrefix("pmset lowpowermode") || $0.contains("lowpower") }, "\(h.events.all)")

        h.source.set(lid(true))
        _ = await h.engine.evaluate()
        #expect(await h.engine.nextCheckDelay() <= SessionEngine.lidSettle + 0.1)
        h.clock.advance(SessionEngine.lidSettle)
        let settled = await h.engine.evaluate()
        #expect(settled.power?.lidClosed == true)
        #expect(settled.lowPowerHeld)
    }
}

@Suite struct ProcessTreeTests {
    @Test func descendantsBreadthFirst() {
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 10, 13: 11, 20: 1, 21: 20]
        #expect(ProcessTree.descendants(of: 10, parents: parents) == [10, 11, 12, 13])
        #expect(ProcessTree.descendants(of: 99, parents: parents) == [99])
    }
}
