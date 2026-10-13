import DarraOwlCore
import Foundation
import Network

/// Claude Code's HTTP hooks endpoint: 127.0.0.1 only, one path, a bearer
/// token. Read: the event name, its type, the folder, and for a permission
/// request the tool and what it would do. A permission request's connection
/// is held until the phone answers (or not), then gets the decision.
@MainActor
public final class HookServer {
    public static let port: UInt16 = 52_526

    public private(set) var isListening = false
    public private(set) var lastSignal: Date?
    private var listener: NWListener?
    private let token: String
    private let onHook: (ClaudeHook.Parsed) -> Void
    /// A permission request and its id: the decision once known, nil for none.
    private let onPermission: (UUID, ClaudeHook.Permission) async -> AgentApprovals.Decision?
    /// Claude stopped waiting for request `id` (interrupted, quit).
    private let onWithdraw: (UUID) -> Void
    /// Connections held for a permission request: not cut after 5 s.
    private var held: Set<ObjectIdentifier> = []

    public init(
        token: String, onHook: @escaping (ClaudeHook.Parsed) -> Void,
        onPermission: @escaping (UUID, ClaudeHook.Permission) async -> AgentApprovals.Decision? = { _, _ in nil },
        onWithdraw: @escaping (UUID) -> Void = { _ in }
    ) {
        self.token = token
        self.onHook = onHook
        self.onPermission = onPermission
        self.onWithdraw = onWithdraw
    }

    public func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.stateUpdateHandler = { [weak self, weak l] state in
            Task { @MainActor in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready:
                    self.isListening = true
                case .failed:
                    // Port taken, for instance: dropped, so the next start()
                    // really tries again.
                    self.isListening = false
                    l.cancel()
                    self.listener = nil
                case .cancelled:
                    self.isListening = false
                    self.listener = nil
                default:
                    break
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.serve(c) }
        }
        l.start(queue: .main)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func serve(_ c: NWConnection) {
        // Loopback only, whatever the listener was told.
        if case let .hostPort(host, _) = c.endpoint, "\(host)" != "127.0.0.1" {
            c.cancel()
            return
        }
        c.start(queue: .main)
        read(c, buffer: Data())
        Task { [weak self, weak c] in
            try? await Task.sleep(for: .seconds(5))
            guard let c, self?.held.contains(ObjectIdentifier(c)) != true else { return }
            c.cancel()
        }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch LocalHTTP.parse(buffer) {
                case .incomplete where !complete && error == nil:
                    self.read(c, buffer: buffer)
                case let .request(r):
                    self.answer(c, r)
                default:
                    self.reply(c, 400, "Bad Request")
                }
            }
        }
    }

    private func answer(_ c: NWConnection, _ r: LocalHTTP.Request) {
        guard r.method == "POST", r.path == "/hooks/claude" else { return reply(c, 404, "Not Found") }
        guard LocalHTTP.authorized(r, token: token) else { return reply(c, 401, "Unauthorized") }
        guard let parsed = ClaudeHook.parse(r.body) else { return reply(c, 400, "Bad Request") }
        lastSignal = Date()
        if case let .permission(request) = parsed {
            hold(c, request)
            return
        }
        onHook(parsed)
        reply(c, 200, "OK")
    }

    /// Answered once the phone has, or not: the connection stays open
    /// meanwhile, and its closing withdraws the request.
    private func hold(_ c: NWConnection, _ request: ClaudeHook.Permission) {
        let id = UUID()
        let key = ObjectIdentifier(c)
        held.insert(key)
        watchClose(c, key: key, id: id)
        Task {
            // Closed before the request was registered: nothing would withdraw it.
            guard held.contains(key) else { return }
            let decision = await onPermission(id, request)
            guard held.remove(key) != nil else { return }
            reply(c, 200, "OK", body: AgentApprovals.hookAnswer(decision))
        }
    }

    /// A read that only ends when Claude closes its side.
    private func watchClose(_ c: NWConnection, key: ObjectIdentifier, id: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            Task { @MainActor in
                guard let self, self.held.contains(key) else { return }
                if complete || error != nil {
                    self.held.remove(key)
                    c.cancel()
                    self.onWithdraw(id)
                } else {
                    self.watchClose(c, key: key, id: id)
                }
            }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ text: String, body: Data = Data("{}".utf8)) {
        c.send(content: LocalHTTP.response(status, text, body: body), completion: .contentProcessed { _ in c.cancel() })
    }
}
