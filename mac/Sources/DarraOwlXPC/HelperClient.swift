import Foundation
import Synchronization

public enum HelperClientError: Error, LocalizedError, Sendable {
    case unsignedBuild
    case noProxy
    case badReply
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unsignedBuild: "Cette version de DarraOwl n'est pas signée : le composant système refuse de lui répondre."
        case .noProxy: "Composant système injoignable."
        case .badReply: "Réponse illisible du composant système."
        case .timedOut: "Le composant système ne répond pas."
        }
    }
}

/// XPC connection to the privileged helper, for the app and the CLI. The
/// helper must satisfy a code requirement pinned to the caller's own Team ID.
@MainActor
public final class HelperClient {
    private var connection: NSXPCConnection?

    public init() {}

    /// Every pmset call the helper makes is bounded, so a request that takes
    /// longer than `timeout` is stuck: the caller is told rather than left
    /// waiting (a quit, a logout, a terminal).
    public static let defaultTimeout: TimeInterval = 120

    public func send(_ request: HelperRequest, timeout: TimeInterval = HelperClient.defaultTimeout) async throws -> HelperResponse {
        let connection = try currentConnection()
        let data = try HelperCoding.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let done = Mutex(false)
            let finish: @Sendable (Result<HelperResponse, Error>) -> Void = { result in
                let first = done.withLock { already in
                    defer { already = true }
                    return !already
                }
                if first { continuation.resume(with: result) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                finish(.failure(error))
            } as? HelperXPCProtocol
            guard let proxy else {
                finish(.failure(HelperClientError.noProxy))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HelperClientError.timedOut))
            }
            proxy.handle(data) { @Sendable reply in
                do {
                    finish(.success(try HelperCoding.decode(HelperResponse.self, from: reply)))
                } catch {
                    finish(.failure(HelperClientError.badReply))
                }
            }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func currentConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let team = CodeRequirements.currentTeamID(), let requirement = CodeRequirements.helper(teamID: team) else {
            throw HelperClientError.unsignedBuild
        }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        c.setCodeSigningRequirement(requirement)
        // A late handler of an older connection must not drop the current one.
        let id = ObjectIdentifier(c)
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                if let self, let current = self.connection, ObjectIdentifier(current) == id { self.connection = nil }
            }
        }
        c.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                if let self, let current = self.connection, ObjectIdentifier(current) == id { self.connection = nil }
            }
        }
        c.resume()
        connection = c
        return c
    }
}
