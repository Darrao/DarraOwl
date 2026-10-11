import CryptoKit
import DarraOwlShared
import Foundation
import Network
import Security

/// One accepted connection: frames in, frames out.
@MainActor
final class LinkConnection {
    let connection: NWConnection
    var deviceID: UUID?
    private var framer = Framer()
    var onMessage: ((LinkConnection, ClientMessage) -> Void)?
    var onClose: ((LinkConnection) -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled: self.onClose?(self)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: ServerMessage) {
        guard let data = try? Framer.frame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        for body in try self.framer.push(data) {
                            guard let message = try? LinkCoding.decoder().decode(ClientMessage.self, from: body) else {
                                self.close()
                                return
                            }
                            self.onMessage?(self, message)
                        }
                    } catch {
                        self.close()
                        return
                    }
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }
}

/// The Mac's direct server: one listener for paired devices (advertised by
/// Bonjour), and while a QR code is on screen, a second one that only
/// accepts a pairing request.
@MainActor
public final class LinkServer {
    public struct Handlers {
        /// Answer to a paired device's message; `nil` sends nothing.
        public var message: (UUID, ClientMessage) async -> ServerMessage?
        public var pairing: (PairingRequest) -> PairingResponse
        /// Checked at hello and before every later message, so an unpaired
        /// device is cut off even on an open connection.
        public var isPaired: (UUID) -> Bool

        public init(
            message: @escaping (UUID, ClientMessage) async -> ServerMessage?,
            pairing: @escaping (PairingRequest) -> PairingResponse,
            isPaired: @escaping (UUID) -> Bool
        ) {
            self.message = message
            self.pairing = pairing
            self.isPaired = isPaired
        }
    }

    public private(set) var port: UInt16?
    public private(set) var pairingPort: UInt16?
    public private(set) var lastError: String?

    private let macID: UUID
    private let macName: String
    private let handlers: Handlers
    private var listener: NWListener?
    private var pairingListener: NWListener?
    private var connections: [ObjectIdentifier: LinkConnection] = [:]

    public init(macID: UUID, macName: String, handlers: Handlers) {
        self.macID = macID
        self.macName = macName
        self.handlers = handlers
    }

    /// (Re)starts the main listener with the current paired devices' keys.
    /// Called again after each pairing or unpairing.
    public func start(keys: [(deviceID: UUID, key: SymmetricKey)], anyPort: Bool = false) {
        listener?.cancel()
        listener = nil
        guard !keys.isEmpty else { return }
        let tls = LinkTLS.options(keys: keys.map { ($0.deviceID.uuidString, $0.key) })
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        do {
            // A fixed port, so the address published to iCloud stays valid
            // for Tailscale; any free port if it is taken.
            let l = anyPort ? try NWListener(using: params) : try NWListener(using: params, on: NWEndpoint.Port(rawValue: LinkProtocol.defaultPort)!)
            l.service = NWListener.Service(name: macName, type: LinkProtocol.bonjourType, txtRecord: NWTXTRecord(["mac": macID.uuidString]))
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = l.port?.rawValue; self.lastError = nil
                    case let .failed(e):
                        self.port = nil
                        if !anyPort {
                            self.start(keys: keys, anyPort: true)
                        } else {
                            self.lastError = e.localizedDescription
                        }
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in self?.accept(c, pairingOnly: false) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Listener for the invite on screen, keyed by its one-time secret.
    public func startPairing(identity: String, key: SymmetricKey) {
        stopPairing()
        let params = NWParameters(tls: LinkTLS.options(keys: [(identity, key)]), tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        guard let l = try? NWListener(using: params) else { return }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.pairingPort = l.port?.rawValue }
            }
        }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.accept(c, pairingOnly: true) }
        }
        l.start(queue: .main)
        pairingListener = l
    }

    public func stopPairing() {
        pairingListener?.cancel()
        pairingListener = nil
        pairingPort = nil
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stopPairing()
        connections.values.forEach { $0.close() }
        connections.removeAll()
    }

    /// Sends to every device that said hello.
    public func broadcast(_ message: ServerMessage) {
        for c in connections.values where c.deviceID != nil {
            c.send(message)
        }
    }

    /// Drops a device's open connections at once (unpairing).
    public func disconnect(deviceID: UUID) {
        for c in connections.values where c.deviceID == deviceID {
            c.close()
        }
    }

    public var connectedDevices: Set<UUID> {
        Set(connections.values.compactMap(\.deviceID))
    }

    // MARK: Private

    private func accept(_ nw: NWConnection, pairingOnly: Bool) {
        let c = LinkConnection(nw)
        connections[ObjectIdentifier(c)] = c
        c.onClose = { [weak self] c in
            self?.connections[ObjectIdentifier(c)] = nil
        }
        c.onMessage = { [weak self] c, message in
            guard let self else { return }
            Task { @MainActor in await self.handle(message, on: c, pairingOnly: pairingOnly) }
        }
        c.start()
    }

    private func handle(_ message: ClientMessage, on c: LinkConnection, pairingOnly: Bool) async {
        if pairingOnly {
            guard case let .pair(request) = message else {
                c.close()
                return
            }
            c.send(.paired(handlers.pairing(request)))
            return
        }
        if case let .hello(version, deviceID) = message {
            guard version == LinkProtocol.version else {
                c.send(.error("Version du protocole différente : mets à jour DarraOwl."))
                c.close()
                return
            }
            guard handlers.isPaired(deviceID) else {
                c.close()
                return
            }
            c.deviceID = deviceID
            c.send(.hello(protocolVersion: LinkProtocol.version, macID: macID))
            if let state = await handlers.message(deviceID, .getState) { c.send(state) }
            return
        }
        guard let deviceID = c.deviceID, handlers.isPaired(deviceID) else {
            c.close()
            return
        }
        switch message {
        case .getState, .command:
            if let answer = await handlers.message(deviceID, message) { c.send(answer) }
        case .hello, .pair:
            c.close()
        }
    }
}
