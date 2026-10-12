@testable import DarraOwlCore
import Foundation
import Testing

/// The Mac app's updates: what is taken from GitHub's answer, and when an
/// update may replace the app.
@Suite struct UpdatesTests {
    func answer(tag: String, assets: [(String, String)], draft: Bool = false, prerelease: Bool = false) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list)]}"#.utf8)
    }

    let base = "https://github.com/Darrao/DarraOwl/releases/download/v0.2.0/"

    @Test func theZipAndItsHashAreFound() throws {
        let release = try #require(ReleaseCheck.latest(fromGitHub: answer(tag: "v0.2.0", assets: [
            ("DarraOwl-0.2.0.zip", base + "DarraOwl-0.2.0.zip"),
            ("DarraOwl-0.2.0.zip.sha256", base + "DarraOwl-0.2.0.zip.sha256"),
        ])))
        #expect(release.version == "0.2.0")
        #expect(release.zipURL.lastPathComponent == "DarraOwl-0.2.0.zip")
        #expect(release.checksumURL?.lastPathComponent == "DarraOwl-0.2.0.zip.sha256")
    }

    @Test func draftsPreReleasesAndForeignLinksAreIgnored() {
        let zip = [("DarraOwl-0.2.0.zip", base + "DarraOwl-0.2.0.zip")]
        #expect(ReleaseCheck.latest(fromGitHub: answer(tag: "v0.2.0", assets: zip, draft: true)) == nil)
        #expect(ReleaseCheck.latest(fromGitHub: answer(tag: "v0.2.0", assets: zip, prerelease: true)) == nil)
        #expect(ReleaseCheck.latest(fromGitHub: answer(tag: "nightly", assets: zip)) == nil)
        #expect(ReleaseCheck.latest(fromGitHub: answer(tag: "v0.2.0", assets: [("DarraOwl-0.2.0.zip", "https://example.com/DarraOwl-0.2.0.zip")])) == nil)
        #expect(ReleaseCheck.latest(fromGitHub: answer(tag: "v0.2.0", assets: [("DarraOwl-0.2.0.zip", "http://github.com/Darrao/DarraOwl/releases/download/v0.2.0/DarraOwl-0.2.0.zip")])) == nil)
        #expect(ReleaseCheck.latest(fromGitHub: Data("garbage".utf8)) == nil)
    }

    @Test func versionsCompareNumerically() {
        #expect(ReleaseCheck.isNewer("0.1.10", than: "0.1.9"))
        #expect(ReleaseCheck.isNewer("0.2", than: "0.1.9"))
        #expect(ReleaseCheck.isNewer("1.0.0", than: "0.9.9"))
        #expect(!ReleaseCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!ReleaseCheck.isNewer("0.1.0", than: "0.1.1"), "never back to an older one")
        #expect(!ReleaseCheck.isNewer("0.1.0.0", than: "0.1"))
        #expect(!ReleaseCheck.isNewer("1.0-beta", than: "0.9"), "unreadable is not newer")
    }

    @Test func theHashIsReadFromTheShasumLine() {
        let hash = String(repeating: "ab", count: 32)
        #expect(ReleaseCheck.checksum(fromShasumLine: "\(hash)  DarraOwl-0.2.0.zip\n", fileName: "DarraOwl-0.2.0.zip") == hash)
        #expect(ReleaseCheck.checksum(fromShasumLine: "\(hash.uppercased()) *DarraOwl-0.2.0.zip", fileName: "DarraOwl-0.2.0.zip") == hash)
        #expect(ReleaseCheck.checksum(fromShasumLine: "\(hash)  Other.zip", fileName: "DarraOwl-0.2.0.zip") == nil)
        #expect(ReleaseCheck.checksum(fromShasumLine: "1234  DarraOwl-0.2.0.zip", fileName: "DarraOwl-0.2.0.zip") == nil)
    }

    /// A version this macOS cannot open is never put in place.
    @Test func theMinimumMacOSIsRead() {
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        #expect(ReleaseCheck.runs(minimum: nil, on: system))
        #expect(ReleaseCheck.runs(minimum: "26.0", on: system))
        #expect(ReleaseCheck.runs(minimum: "27.0.1", on: system))
        #expect(!ReleaseCheck.runs(minimum: "27.1", on: system))
        #expect(!ReleaseCheck.runs(minimum: "28", on: system))
        #expect(!ReleaseCheck.runs(minimum: "27.x", on: system), "unreadable: refused")
    }

    /// Quitting ends a session and a timed "Toujours actif": never then,
    /// and never under the user's hands.
    @Test func anUpdateWaitsForNothingToRun() {
        #expect(UpdatePolicy.mayInstall(sessionRunning: false, timedPresence: false, userIdle: 300))
        #expect(!UpdatePolicy.mayInstall(sessionRunning: true, timedPresence: false, userIdle: 300))
        #expect(!UpdatePolicy.mayInstall(sessionRunning: false, timedPresence: true, userIdle: 300))
        #expect(!UpdatePolicy.mayInstall(sessionRunning: false, timedPresence: false, userIdle: 10))
    }
}
