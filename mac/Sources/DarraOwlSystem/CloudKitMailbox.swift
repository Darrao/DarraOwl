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
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    public func fetchInbox() async throws -> CloudInbox {
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
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    public func deliver(pairing: PairingResponse, requestID: String) async throws {
        let record = CKRecord(recordType: "PairingResponse", recordID: CKRecord.ID(recordName: "pairing-\(requestID)", zoneID: zoneID))
        record["macID"] = macID.uuidString
        record.encryptedValues["payload"] = try LinkCoding.encoder().encode(pairing)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    public func discard(itemIDs: [String]) async throws {
        let ids = itemIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
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
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        var sent = UserDefaults.standard.dictionary(forKey: Self.eventsKey) as? [String: Date] ?? [:]
        sent[record.recordID.recordName] = event.at
        UserDefaults.standard.set(sent, forKey: Self.eventsKey)
    }

    public func removeEvents(before date: Date) async {
        var sent = UserDefaults.standard.dictionary(forKey: Self.eventsKey) as? [String: Date] ?? [:]
        let old = sent.filter { $0.value < date }.map(\.key)
        guard !old.isEmpty else { return }
        if (try? await database.modifyRecords(saving: [], deleting: old.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })) != nil {
            old.forEach { sent[$0] = nil }
            UserDefaults.standard.set(sent, forKey: Self.eventsKey)
        }
    }

    static let eventsKey = "cloudSentEvents"

    /// Deletes this Mac's records (uninstall).
    public func removeEverything() async {
        _ = try? await database.deleteRecordZone(withID: zoneID)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    // MARK: Private

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
