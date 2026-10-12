import Foundation

/// A published version of the Mac app, from the GitHub releases.
public struct AppRelease: Equatable, Sendable {
    /// "0.1.1", without the "v" of the tag.
    public var version: String
    public var zipURL: URL
    /// The `shasum -a 256` line published next to the zip.
    public var checksumURL: URL?

    public init(version: String, zipURL: URL, checksumURL: URL?) {
        self.version = version
        self.zipURL = zipURL
        self.checksumURL = checksumURL
    }
}

/// Reads GitHub's "latest release" answer and compares versions. Pure.
public enum ReleaseCheck {
    public static let repository = "Darrao/DarraOwl"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }

        var tag_name: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    /// The app's zip in GitHub's answer, or nil: a draft, a pre-release, a
    /// tag that is not a version, or no zip. Only download links of this
    /// repository's own releases are taken.
    public static func latest(fromGitHub data: Data) -> AppRelease? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              release.draft != true, release.prerelease != true
        else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard components(version) != nil else { return nil }
        let zipName = "DarraOwl-\(version).zip"
        func url(_ name: String) -> URL? {
            guard let asset = release.assets.first(where: { $0.name == name }),
                  let url = URL(string: asset.browser_download_url), isOwnDownload(url)
            else { return nil }
            return url
        }
        guard let zip = url(zipName) else { return nil }
        return AppRelease(version: version, zipURL: zip, checksumURL: url(zipName + ".sha256"))
    }

    /// https://github.com/Darrao/DarraOwl/releases/download/…
    public static func isOwnDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repository)/releases/download/")
    }

    /// "0.1.10" is newer than "0.1.9". Anything unreadable is not newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { p -> Int? in
            guard !p.isEmpty, p.count <= 6, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber) else { return nil }
            return Int(p)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    /// Whether an app asking for macOS `minimum` ("26.0") runs on `system`.
    /// Unreadable: it does not.
    public static func runs(minimum: String?, on system: OperatingSystemVersion) -> Bool {
        guard let minimum else { return true }
        let wanted = minimum.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !wanted.isEmpty, wanted.allSatisfy({ $0 != nil }) else { return false }
        let have = [system.majorVersion, system.minorVersion, system.patchVersion]
        for i in 0..<max(wanted.count, have.count) {
            let w = i < wanted.count ? wanted[i]! : 0
            let h = i < have.count ? have[i] : 0
            if w != h { return h > w }
        }
        return true
    }

    /// The hash in a `shasum -a 256` line for this file name, lower case.
    public static func checksum(fromShasumLine text: String, fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == fileName else { continue }
            let hash = fields[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return hash
        }
        return nil
    }
}

/// When a downloaded update may replace the running app: quitting ends a
/// session and a timed "Toujours actif" (it does not survive a relaunch),
/// and nobody should be in the middle of using DarraOwl.
public enum UpdatePolicy {
    public static let idleBeforeInstall: TimeInterval = 120

    public static func mayInstall(sessionRunning: Bool, timedPresence: Bool, userIdle: TimeInterval) -> Bool {
        !sessionRunning && !timedPresence && userIdle >= idleBeforeInstall
    }
}
