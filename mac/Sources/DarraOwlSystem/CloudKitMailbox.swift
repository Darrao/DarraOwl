import CloudKit
import DarraOwlCore
import DarraOwlShared
import Foundation

/// The user's private CloudKit database, custom zone `DarraOwl`. Nothing
/// goes to a server of ours. Payloads use `encryptedValues`, encrypted with
/// keys held in the user's iCloud Keychain.
///
/// Record types:
/// - `MacState` (name = mac id): `macID`, `macName`, `updatedAt`, `power`,
///   `protocolVersion`, encrypted `state` (MacState JSON) and `endpoints`.
/// - `Command` (phone → Mac): `macID`, `expiresAt`, encrypted `payload` (SignedCommand).
/// - `CommandResult` (name = "result-<command id>"): `macID`, `commandID`,
///   `status`, `at`, encrypted `message`.
/// - `PairingRequest` (phone → Mac): `macID`, encrypted `payload`.
/// - `PairingResponse` (name = "pairing-<request record name>"): encrypted `payload`.
@MainActor
public final class CloudKitMailbox: CloudMailbox {
    public static let containerID = "iCloud.com.darrao.darraowl"
    public static let zoneName = "DarraOwl"
    static let tokenKey = "cloudZoneChangeToken"
    static let subscriptionID = "mac-inbox"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitMailbox.zoneName)
    private let macID: UUID
    private var zoneReady = false

    public init(macID: UUID) {
        self.macID = macID
        container = CKContainer(identifier: Self.containerID)
        database = container.privateCloudDatabase
    }

    /// nil when iCloud can be used, otherwise why not (French).
    public func accountProblem() async -> String? {
        do {
            switch try await container.accountStatus() {
            case .available: return nil
            case .noAccount: return "Aucun compte iCloud sur ce Mac."
            case .restricted: return "iCloud est restreint sur ce Mac."
            case .temporarilyUnavailable: return "iCloud est momentanément indisponible."
            case .couldNotDetermine: return "État du compte iCloud inconnu."
            @unknown default: return "État du compte iCloud inconnu."
            }
        } catch {
            return "iCloud : \(error.localizedDescription)"
        }
    }

    public func publish(state: MacState, endpoints: Endpoints?) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: "MacState", recordID: CKRecord.ID(recordName: macID.uuidString, zoneID: zoneID))
        record["macID"] = macID.uuidString
        record["macName"] = state.macName
        record["updatedAt"] = state.updatedAt
        record["power"] = state.power.rawValue
        record["protocolVersion"] = state.protocolVersion
        record.encryptedValues["state"] = try LinkCoding.encoder().encode(state)
        if let endpoints { record.encryptedValues["endpoints"] = try LinkCoding.encoder().encode(endpoints) }
        try await save(record)
    }

    public func fetchInbox() async throws -> CloudInbox {
        do {
            return try await fetchInboxOnce()
        } catch let error as CKError where error.code == .changeTokenExpired {
            // A token from another environment or an old zone: start over.
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            return try await fetchInboxOnce()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The zone was deleted elsewhere: make it again, read from the start.
            zoneReady = false
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            return try await fetchInboxOnce()
        }
    }

    private func fetchInboxOnce() async throws -> CloudInbox {
        try await ensureZone()
        var inbox = CloudInbox()
        var token = savedToken()
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                guard case let .success(modification) = result else { continue }
                let record = modification.record
                guard record["macID"] as? String == macID.uuidString,
                      let payload = record.encryptedValues["payload"] as? Data
                else { continue }
                switch record.recordType {
                case "Command":
                    if let c = try? LinkCoding.decoder().decode(SignedCommand.self, from: payload) {
                        inbox.commands.append((id.recordName, c))
                    }
                case "PairingRequest":
                    if let r = try? LinkCoding.decoder().decode(PairingRequest.self, from: payload) {
                        inbox.pairings.append((id.recordName, r))
                    }
                default:
                    break
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        save(token: token)
        return inbox
    }

    public func deliver(result: CommandResult) async throws {
        let record = CKRecord(recordType: "CommandResult", recordID: CKRecord.ID(recordName: "result-\(result.commandID.uuidString)", zoneID: zoneID))
        record["macID"] = macID.uuidString
        record["commandID"] = result.commandID.uuidString
        record["status"] = result.status.rawValue
        record["at"] = result.at
        record.encryptedValues["message"] = result.message
        try await save(record)
        remember(record.recordID.recordName, at: result.at, key: Self.resultsKey)
    }

    public func deliver(pairing: PairingResponse, requestID: String) async throws {
        let record = CKRecord(recordType: "PairingResponse", recordID: CKRecord.ID(recordName: "pairing-\(requestID)", zoneID: zoneID))
        record["macID"] = macID.uuidString
        record.encryptedValues["payload"] = try LinkCoding.encoder().encode(pairing)
        try await save(record)
    }

    public func discard(itemIDs: [String]) async throws {
        try await delete(itemIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
    }

    public func post(_ event: MacEvent) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "event-\(event.id.uuidString)", zoneID: zoneID))
        record["macID"] = macID.uuidString
        record["kind"] = event.kind.rawValue
        record["category"] = event.category
        // Plain, so the notification shows them without the app.
        record["title"] = event.title
        record["body"] = event.body
        record["at"] = event.at
        try await save(record)
        remember(record.recordID.recordName, at: event.at, key: Self.eventsKey)
    }

    /// One event, by id. A Claude request's event has the request's id: once
    /// answered, its detail leaves iCloud.
    public func removeEvent(id: UUID) async {
        let name = "event-\(id.uuidString)"
        // Gone already counts as deleted.
        guard (try? await delete([CKRecord.ID(recordName: name, zoneID: zoneID)])) != nil else { return }
        var sent = UserDefaults.standard.dictionary(forKey: Self.eventsKey) as? [String: Date] ?? [:]
        sent[name] = nil
        UserDefaults.standard.set(sent, forKey: Self.eventsKey)
    }

    /// Deletes this Mac's events, and the results the phone did not read
    /// (Siri and Live Activity commands do not wait for them), older than `date`.
    public func removeEvents(before date: Date) async {
        for key in [Self.eventsKey, Self.resultsKey] {
            var sent = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
            let old = sent.filter { $0.value < date }.map(\.key)
            // CloudKit takes 400 items per request at most: by 300, so a long
            // list shrinks even when one batch fails.
            for start in stride(from: 0, to: old.count, by: 300) {
                let batch = Array(old[start..<min(start + 300, old.count)])
                // Gone already (read by the phone) counts as deleted.
                guard (try? await delete(batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })) != nil else { break }
                batch.forEach { sent[$0] = nil }
                UserDefaults.standard.set(sent, forKey: key)
            }
        }
    }

    static let eventsKey = "cloudSentEvents"
    static let resultsKey = "cloudSentResults"

    /// Deletes this Mac's records (uninstall). The zone is shared with the
    /// user's other Macs and with the phone: it goes only when no other
    /// Mac's state is left in it.
    public func removeEverything() async {
        do {
            var mine: [CKRecord.ID] = []
            var otherMacs = false
            var token: CKServerChangeToken?
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (id, result) in changes.modificationResultsByID {
                    guard case let .success(modification) = result else { continue }
                    let record = modification.record
                    if record["macID"] as? String == macID.uuidString || id.recordName == macID.uuidString {
                        mine.append(id)
                    } else if record.recordType == "MacState" {
                        otherMacs = true
                    }
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            if otherMacs {
                for start in stride(from: 0, to: mine.count, by: 300) {
                    try await delete(Array(mine[start..<min(start + 300, mine.count)]))
                }
            } else {
                _ = try await database.deleteRecordZone(withID: zoneID)
                _ = try? await database.deleteSubscription(withID: Self.subscriptionID)
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Nothing left to delete.
        } catch {
            // Best effort: the user can still delete DarraOwl's data in iCloud settings.
        }
        zoneReady = false
        for key in [Self.tokenKey, Self.eventsKey, Self.resultsKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: Private

    /// Saves one record. `modifyRecords` throws only when the whole request
    /// fails: a refused record is reported in its result, read here.
    private func save(_ record: CKRecord) async throws {
        try await ensureZone()
        do {
            let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case let .failure(error)? = saved[record.recordID] { throw error }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Deleted elsewhere (another Mac's uninstall, iCloud settings): made again next time.
            zoneReady = false
            throw error
        }
    }

    /// Deletes records; one that is already gone is not an error.
    private func delete(_ ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        let (_, deleted) = try await database.modifyRecords(saving: [], deleting: ids)
        for (_, result) in deleted {
            if case let .failure(error) = result, (error as? CKError)?.code != .unknownItem { throw error }
        }
    }

    private func remember(_ recordName: String, at date: Date, key: String) {
        var sent = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
        sent[recordName] = date
        UserDefaults.standard.set(sent, forKey: key)
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        // Silent push when the phone writes to the zone; polling covers the rest.
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await database.modifySubscriptions(saving: [subscription], deleting: [])
        zoneReady = true
    }

    private func savedToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func save(token: CKServerChangeToken?) {
        guard let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: Self.tokenKey)
    }
}
