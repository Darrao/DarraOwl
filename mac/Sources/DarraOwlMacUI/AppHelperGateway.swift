import DarraOwlCore
import DarraOwlXPC
import Foundation

struct HelperRefusal: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The lid coordinator's requests, sent over XPC. Every answer also updates
/// the app's copy of the status.
@MainActor
final class AppHelperGateway: LidHelperGateway {
    private let client: HelperClient
    private let onStatus: (EngineStatus) -> Void

    init(client: HelperClient, onStatus: @escaping (EngineStatus) -> Void) {
        self.client = client
        self.onStatus = onStatus
    }

    func recordUserChanges(_ changes: UserChanges) async throws -> EngineStatus { try await send(.recordUserChanges(changes)) }
    func clearUserChanges(_ kinds: [UserChangeKind]) async throws -> EngineStatus { try await send(.clearUserChanges(kinds)) }
    func freeze(_ groups: [FreezeGroup]) async throws -> EngineStatus { try await send(.freeze(groups)) }
    func resume(bundleID: String?) async throws -> EngineStatus { try await send(.resume(bundleID: bundleID)) }
    func lidChanged() async throws -> EngineStatus { try await send(.lidChanged) }

    private func send(_ request: HelperRequest) async throws -> EngineStatus {
        let response = try await client.send(request)
        if let status = response.status { onStatus(status) }
        if let error = response.error { throw LidHelperRefusal(message: error, status: response.status) }
        guard let status = response.status else { throw HelperClientError.badReply }
        return status
    }
}
