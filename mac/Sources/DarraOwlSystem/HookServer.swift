import DarraOwlCore
import Foundation
import Network

/// Claude Code's HTTP hooks endpoint: 127.0.0.1 only, one path, a bearer
/// token. Nothing but the event name and the folder is read.
@MainActor
public final class HookServer {
    public static let port: UInt16 = 52_526

    public private(set) var isListening = false
    public private(set) var lastSignal: Date?
    private var listener: NWListener?
    private let token: String
    private let onHook: (ClaudeHook.Parsed) -> Void

    public init(token: String, onHook: @escaping (ClaudeHook.Parsed) -> Void) {
        self.token = token
        self.onHook = onHook
    }

    public func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isListening = true
                case .failed, .cancelled: self?.isListening = false
                default: break
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
    }

    private func serve(_ c: NWConnection) {
        // Loopback only, whatever the listener was told.
        if case let .hostPort(host, _) = c.endpoint, "\(host)" != "127.0.0.1" {
            c.cancel()
            return
        }
        c.start(queue: .main)
        read(c, buffer: Data())
        Task { [weak c] in
            try? await Task.sleep(for: .seconds(5))
            c?.cancel()
        }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
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
        onHook(parsed)
        reply(c, 200, "OK")
    }

    private func reply(_ c: NWConnection, _ status: Int, _ text: String) {
        c.send(content: LocalHTTP.response(status, text), completion: .contentProcessed { _ in c.cancel() })
    }
}
