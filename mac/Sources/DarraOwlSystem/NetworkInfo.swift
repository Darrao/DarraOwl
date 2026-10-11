import DarraOwlCore
import DarraOwlShared
import Darwin
import Foundation
import Network

/// The Mac's IPv4 addresses and the kind of network it uses.
@MainActor
public final class NetworkInfo {
    public private(set) var kind: MacState.NetworkKind = .none
    public var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let kind = Self.kind(of: path)
                if kind != self.kind {
                    self.kind = kind
                    self.onChange?()
                }
            }
        }
        monitor.start(queue: .main)
    }

    nonisolated static func kind(of path: NWPath) -> MacState.NetworkKind {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi) {
            let hotspot = path.isExpensive || interfaces().contains { $0.name == "en0" && EndpointPicker.isHotspot($0.ipv4) }
            return hotspot ? .hotspot : .wifi
        }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .other
    }

    /// Every IPv4 address with its interface name.
    public nonisolated static func interfaces() -> [EndpointPicker.Interface] {
        var result: [EndpointPicker.Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(decoding: Data(bytes: p.pointee.ifa_name, count: strlen(p.pointee.ifa_name)), as: UTF8.self)
            result.append(.init(name: name, ipv4: ip))
        }
        return result
    }
}

/// Docker Desktop's containers, through its own socket.
@MainActor
public final class DockerControl {
    public init() {}

    private func docker() throws -> (String, String) {
        guard let path = DockerDesktopProbe.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProcessError(command: "docker", detail: "introuvable")
        }
        return (path, "unix://\(NSHomeDirectory())/.docker/run/docker.sock")
    }

    /// Running containers, or [] when Docker is absent, stopped or paused.
    public func containers() async -> [MacState.Container] {
        guard let (path, host) = try? docker(),
              let out = try? await ProcessRunner.runChecked(path, ["--host", host, "ps", "--format", "{{.ID}}\t{{.Names}}"], timeout: 3)
        else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, CommandKind.isWellFormedContainerID(parts[0]) else { return nil }
            return MacState.Container(id: parts[0], name: parts[1])
        }
    }

    /// `docker stop <id>`; `id` was checked against the running list.
    public func stop(id: String) async throws {
        guard CommandKind.isWellFormedContainerID(id) else { throw ProcessError(command: "docker stop", detail: "identifiant refusé") }
        let (path, host) = try docker()
        try await ProcessRunner.runChecked(path, ["--host", host, "stop", id], timeout: 30)
    }
}
