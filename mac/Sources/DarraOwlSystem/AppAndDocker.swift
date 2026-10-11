import AppKit
import DarraOwlCore
import Foundation

/// Running GUI apps (NSWorkspace) and the kernel process table.
@MainActor
public final class WorkspaceProcesses: ProcessSnapshotting {
    public init() {}

    public func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, app.processIdentifier > 1 else { return nil }
            // Some names carry invisible direction marks ("\u{200E}WhatsApp").
            let name = (app.localizedName ?? id).unicodeScalars.filter { $0.properties.generalCategory != .format }
            return RunningApp(pid: app.processIdentifier, bundleID: id, name: String(String.UnicodeScalarView(name)))
        }
    }

    public func processTable() -> [Int32: ProcessState] {
        SysctlProcessControl.snapshot()
    }

    public var currentUID: UInt32 { getuid() }
}

/// `docker --host unix://~/.docker/run/docker.sock ps -q`. Bound to Docker
/// Desktop's own socket, so an ambient DOCKER_HOST or context cannot answer
/// for the Desktop about to be paused.
@MainActor
public final class DockerDesktopProbe: DockerProbing {
    static let candidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "\(NSHomeDirectory())/.docker/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    public init() {}

    public func isIdle() async throws -> Bool {
        guard let docker = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProcessError(command: "docker", detail: "introuvable")
        }
        let socket = "\(NSHomeDirectory())/.docker/run/docker.sock"
        let type = try? FileManager.default.attributesOfItem(atPath: socket)[.type] as? FileAttributeType
        guard type == .typeSocket else { throw ProcessError(command: "docker", detail: "socket de Docker Desktop absent") }
        let out = try await ProcessRunner.runChecked(docker, ["--host", "unix://\(socket)", "ps", "-q"], timeout: 5)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
