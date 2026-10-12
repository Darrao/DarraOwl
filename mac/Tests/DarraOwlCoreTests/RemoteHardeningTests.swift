@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// Pairing takeovers, late copies, self-unpairing, iCloud retries.
@MainActor
@Suite struct RemoteHardeningTests {
    func state(_ rig: HubRig, battery: Int = 80) -> MacState {
        MacState(macID: rig.macID, macName: "MacBook", updatedAt: rig.clock.now(), power: .awake, session: nil,
                 powerSnapshot: PowerSnapshot(battery: .percent(battery), onExternalPower: false, thermal: .nominal),
                 lowPowerActive: false, pausedApps: [], network: nil, dockerPaused: false, settings: .default)
    }

    /// Someone who saw the QR code and knows a paired phone's id (sent in
    /// clear as its TLS identity) cannot replace that phone's keys.
    @Test func aPairedPhonesIDWithOtherKeysIsRefused() throws {
        let rig = HubRig().paired()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        let intruder = TestPhone()
        var request = intruder.pairingRequest(for: invite, at: rig.clock.now())
        request = PairingRequest(macID: request.macID, deviceID: rig.phone.id, deviceName: "iPhone", agreementKey: request.agreementKey,
                                 signingKey: request.signingKey, biometricKey: request.biometricKey, createdAt: rig.clock.now(), secret: invite.secret)
        let answer = rig.hub.handlePairing(request, macName: "MacBook")
        #expect(!answer.accepted)
        #expect(rig.store.stored == [rig.phone.device])
    }

    @Test func thePairingAnswerSaysWhenByTheMacsClock() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        let answer = rig.hub.handlePairing(rig.phone.pairingRequest(for: invite, at: rig.clock.now()), macName: "MacBook")
        #expect(answer.accepted)
        #expect(answer.pairedAt == rig.clock.now())
    }

    /// The iCloud copy of a command that ran, read after its phone was
    /// unpaired: the phone is told what happened, the result is not replaced.
    @Test func aLateCopyFromAnUnpairedPhoneIsAnsweredWithTheRealOutcome() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .direct).status == .executed)
        try rig.hub.unpair(deviceID: rig.phone.id)

        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")

        #expect(rig.cloud.results.map(\.status) == [.executed])
        #expect(rig.ledger.value?.results.map(\.status) == [.executed])
        #expect(rig.target.calls == ["stop"])
    }

    @Test func aPhoneUnpairingItselfRemovesOnlyItsOwnKeys() async throws {
        let rig = HubRig().paired()
        let other = TestPhone()
        rig.store.stored.append(other.device)
        let cmd = try rig.phone.sign(.forgetThisDevice, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .executed)
        #expect(rig.store.stored.map(\.id) == [other.id])
    }

    /// A push that came while a poll ran (a docker stop takes time): the new
    /// command is read right after, not a minute later.
    @Test func aPollAskedForDuringAPollHappensRightAfter() async throws {
        let rig = HubRig().paired()
        rig.target.gate = AsyncGate()
        let first = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c1", first)])
        let running = Task { await rig.hub.pollCloud(macName: "MacBook") }
        await rig.target.gate?.waitUntilEntered()

        let second = try rig.phone.sign(.extendSession(minutes: 60), mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c2", second)])
        await rig.hub.pollCloud(macName: "MacBook")
        rig.target.gate?.open()
        await running.value

        #expect(rig.target.calls == ["stop", "extend 3600"])
        #expect(rig.cloud.discarded == ["c1", "c2"])
    }

    /// A command through iCloud: the Mac's new state leaves before the
    /// result, so the phone reading the state after the result sees it.
    @Test func theNewStateLeavesBeforeTheResult() async throws {
        let rig = HubRig().paired()
        var resultsWhenTheStateLeft: Int?
        rig.hub.afterCommand = { resultsWhenTheStateLeft = rig.cloud.results.count }
        let cmd = try rig.phone.sign(.extendSession(minutes: 60), mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(resultsWhenTheStateLeft == 0, "the state left before any result")
        #expect(rig.cloud.results.count == 1)
    }

    /// "Aussi capot fermé" from the phone: a plain command of the fixed list.
    @Test func thePhoneCanSwitchTheLidClosedOption() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.setPresenceWhileClosed(true), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .direct).status == .executed)
        #expect(rig.target.calls == ["whileClosed true"])
    }

    /// "Going to sleep" while another publish is on its way: sent right after.
    @Test func aForcedPublishWhileOneIsOnItsWayIsSentAfterIt() async {
        let rig = HubRig()
        let gate = AsyncGate()
        rig.cloud.publishGate = gate
        let first = Task { await rig.hub.publishIfDue(state(rig), endpoints: nil) }
        await gate.waitUntilEntered()
        var asleep = state(rig)
        asleep.power = .goingToSleep
        #expect(await !rig.hub.publishIfDue(asleep, endpoints: nil, force: true))
        gate.open()
        _ = await first.value
        #expect(rig.cloud.published.map(\.power) == [.awake, .goingToSleep])
    }

    /// Back online: iCloud is tried at once, not after a back-off of minutes.
    @Test func retryNowEndsTheBackOff() async {
        let rig = HubRig()
        rig.cloud.failPublish = true
        #expect(await !rig.hub.publishIfDue(state(rig), endpoints: nil))
        rig.cloud.failPublish = false
        #expect(await !rig.hub.publishIfDue(state(rig, battery: 70), endpoints: nil), "backing off")
        rig.hub.retryNow()
        #expect(await rig.hub.publishIfDue(state(rig, battery: 70), endpoints: nil))
        #expect(rig.hub.cloudError == nil)
    }

    @Test func aForcedPublishGoesThroughTheBackOff() async {
        let rig = HubRig()
        rig.cloud.failPublish = true
        #expect(await !rig.hub.publishIfDue(state(rig), endpoints: nil))
        rig.cloud.failPublish = false
        #expect(await rig.hub.publishIfDue(state(rig), endpoints: nil, force: true))
    }

    /// A Mac with many virtual machines still gives a list the phone accepts.
    @Test func publishedAddressesAreCappedAndSkipVirtualNetworks() {
        var interfaces = [EndpointPicker.Interface(name: "en0", ipv4: "192.168.1.20")]
        interfaces += (1...12).map { EndpointPicker.Interface(name: "en\($0 + 1)", ipv4: "10.0.\($0).2") }
        interfaces.append(EndpointPicker.Interface(name: "vmnet8", ipv4: "172.16.5.1"))
        interfaces.append(EndpointPicker.Interface(name: "en0", ipv4: "192.168.1.20"))
        let e = EndpointPicker.endpoints(from: interfaces, port: 52525)
        #expect(e.local.count == Endpoints.maxLocal)
        #expect(e.local.first == "192.168.1.20")
        #expect(!e.local.contains("172.16.5.1"))
        #expect(e.isPlausible)
    }
}
