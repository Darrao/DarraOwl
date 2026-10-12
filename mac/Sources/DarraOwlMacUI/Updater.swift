import AppKit
import CryptoKit
import DarraOwlCore
import DarraOwlSystem
import Foundation
import Observation
import Security

enum UpdateError: Error, LocalizedError {
    case checksum
    case signature
    case version
    case system

    var errorDescription: String? {
        switch self {
        case .checksum: "le fichier téléchargé ne correspond pas à celui publié."
        case .signature: "la nouvelle version n'est pas signée par le développeur de DarraOwl."
        case .version: "la nouvelle version ne dit pas être celle annoncée."
        case .system: "la nouvelle version demande une version plus récente de macOS."
        }
    }
}

/// Updates of the Mac app from its GitHub releases, with no outside
/// library: looked for once a day, downloaded, checked (published hash,
/// Developer ID signature of this team, bundle id, version), then put in
/// place of the running app once no session runs and nobody uses the Mac.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)
        case installing(String)
        case failed(String)
    }

    static let automaticKey = "updatesAutomatic"
    static let lastCheckKey = "updatesLastCheck"
    static let checkInterval: TimeInterval = 86_400
    static let teamID = "S3YD258U2R"
    static let bundleID = "com.darrao.darraowl.mac"

    private(set) var phase = Phase.idle
    /// On by default: looked for once a day, installed when nothing runs.
    var automatic: Bool = UserDefaults.standard.object(forKey: Updater.automaticKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.automaticKey) }
    }
    @ObservationIgnored private var ready: (version: String, app: URL)?
    @ObservationIgnored private var working = false
    /// The last checks before an install run: nothing may start meanwhile.
    @ObservationIgnored private(set) var aboutToInstall = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// At launch: the copy an earlier update set aside goes.
    func cleanUpAfterUpdate() {
        try? FileManager.default.removeItem(at: Self.previousURL(for: Bundle.main.bundleURL))
    }

    /// About every minute, from the app model. `mayInstall` is asked only
    /// once an update is ready, right before it would replace the app.
    func tick(mayInstall: () async -> Bool) async {
        if ready != nil {
            if automatic { await installIfAllowed(mayInstall) }
            return
        }
        guard automatic, !working else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        await checkAndDownload()
    }

    /// "Vérifier maintenant", or the daily look.
    func checkAndDownload() async {
        guard !working else { return }
        working = true
        defer { working = false }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        phase = .checking
        do {
            var request = URLRequest(url: ReleaseCheck.latestURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            // 404: nothing published yet.
            guard (response as? HTTPURLResponse)?.statusCode != 404,
                  let release = ReleaseCheck.latest(fromGitHub: data),
                  ReleaseCheck.isNewer(release.version, than: currentVersion)
            else {
                phase = .upToDate
                return
            }
            phase = .downloading(release.version)
            let app = try await download(release)
            ready = (release.version, app)
            phase = .ready(release.version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// "Installer": the same last checks as an automatic install.
    func installNow(mayInstall: () async -> Bool) async {
        await installIfAllowed(mayInstall)
    }

    // MARK: Private

    /// One install at a time: the last checks can take a moment.
    private func installIfAllowed(_ mayInstall: () async -> Bool) async {
        guard let update = ready, !working else { return }
        working = true
        aboutToInstall = true
        defer {
            working = false
            aboutToInstall = false
        }
        guard await mayInstall(), ready?.app == update.app else { return }
        install(update)
    }

    private func download(_ release: AppRelease) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "DarraOwl-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, _) = try await URLSession.shared.download(from: release.zipURL)
        let zip = work.appending(path: "DarraOwl-\(release.version).zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        // The hash published with the release: a damaged download stops here.
        if let checksumURL = release.checksumURL {
            let (text, _) = try await URLSession.shared.data(from: checksumURL)
            guard let expected = ReleaseCheck.checksum(fromShasumLine: String(decoding: text, as: UTF8.self), fileName: zip.lastPathComponent)
            else { throw UpdateError.checksum }
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError.checksum }
        }
        try await ProcessRunner.runChecked("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120)
        let app = work.appending(path: "DarraOwl.app")
        try Self.verify(app, version: release.version)
        return app
    }

    /// The trust anchor: Developer ID, this team, this app, this version.
    static func verify(_ app: URL, version: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.signature }
        let text = "anchor apple generic and identifier \"\(bundleID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signature
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw UpdateError.signature }
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError.version }
        guard ReleaseCheck.runs(minimum: info["LSMinimumSystemVersion"] as? String, on: ProcessInfo.processInfo.operatingSystemVersion)
        else { throw UpdateError.system }
    }

    /// The running copy is set aside, the new one takes its place and
    /// starts, this one quits. Any failure puts the old copy back.
    private func install(_ update: (version: String, app: URL)) {
        // Checked again: the download may be days old, and macOS cleans
        // the temporary folder.
        do {
            try Self.verify(update.app, version: update.version)
        } catch {
            ready = nil
            phase = .failed(error.localizedDescription)
            return
        }
        let current = Bundle.main.bundleURL
        let previous = Self.previousURL(for: current)
        phase = .installing(update.version)
        do {
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: current, to: previous)
            do {
                try FileManager.default.moveItem(at: update.app, to: current)
            } catch {
                try? FileManager.default.moveItem(at: previous, to: current)
                throw error
            }
        } catch {
            ready = nil
            phase = .failed("installation impossible : \(error.localizedDescription)")
            return
        }
        ready = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Unattended: the app in use keeps the focus.
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: current, configuration: configuration) { _, error in
            let reason = error?.localizedDescription
            Task { @MainActor in
                if let reason {
                    self.putBack(current: current, previous: previous, reason: reason)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The new copy does not start on this Mac: the old one goes back in
    /// its place and keeps running.
    private func putBack(current: URL, previous: URL, reason: String) {
        let refused = FileManager.default.temporaryDirectory.appending(path: "DarraOwl-refused-\(UUID().uuidString).app")
        do {
            try FileManager.default.moveItem(at: current, to: refused)
            try FileManager.default.moveItem(at: previous, to: current)
            phase = .failed("la nouvelle version ne démarre pas sur ce Mac (\(reason)) : l'actuelle est gardée.")
        } catch {
            phase = .failed("remise en place impossible (\(error.localizedDescription)) : réinstalle DarraOwl.")
        }
    }

    static func previousURL(for app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: ".DarraOwl-previous.app")
    }
}
