// Adapted from Insomnia (https://github.com/krishhgg/Insomnia), MIT License,
// Copyright (c) 2026 Krish Garg. See THIRD_PARTY_NOTICES.md.
//
// Private frameworks, used only as a last resort: on macOS 26 with sleep
// disabled, closing the lid wakes the panel and keeps it lit, and the public
// `pmset displaysleepnow` does not hold (measured 2026-10-11, see
// docs/lid-close.md). Each call is guarded: DisplayServices only on a macOS
// major it was measured on, CoreBrightness only when every method still has
// the measured type encoding. A refused guard leaves the device alone.

import CoreGraphics
import DarraOwlCore
import Foundation
import IOKit
import IOKit.pwr_mgt
import ObjectiveC.runtime

public struct DisplayPowerError: Error, LocalizedError, Sendable {
    public let what: String
    public var errorDescription: String? { what }
}

public enum DisplayGuards {
    /// macOS major versions the DisplayServices calls were measured on.
    public static let measuredDisplayServicesMajors: Set<Int> = [26]

    public static func displayServicesRefusal(osMajorVersion major: Int) -> String? {
        guard !measuredDisplayServicesMajors.contains(major) else { return nil }
        return "Luminosité de l'écran : appels mesurés sur macOS 26 seulement, macOS \(major) laissé tel quel"
    }

    /// KeyboardBrightnessClient type encodings measured on macOS 26 (arm64),
    /// stack offsets removed.
    public static let measuredKeyboardClientEncodings: [String: String] = [
        "copyKeyboardBacklightIDs": "@@:",
        "isKeyboardBuiltIn:": "B@:Q",
        "brightnessForKeyboard:": "f@:Q",
        "setBrightness:forKeyboard:": "B@:fQ",
    ]

    public static func keyboardClientRefusal(encodingFor: (String) -> String?) -> String? {
        for name in measuredKeyboardClientEncodings.keys.sorted() {
            guard let raw = encodingFor(name) else {
                return "Rétroéclairage du clavier : KeyboardBrightnessClient n'a plus \(name)"
            }
            let found = raw.filter { !$0.isNumber }
            if found != measuredKeyboardClientEncodings[name] {
                return "Rétroéclairage du clavier : \(name) a changé de signature (\(found))"
            }
        }
        return nil
    }

    static func builtInDisplayID() -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return main }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? main
    }
}

/// Private DisplayServices.framework.
@MainActor
public final class DisplayServicesDimmer: DisplayDimming {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Symbols {
        let get: GetBrightness
        let set: SetBrightness
        let canChange: CanChange
    }

    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private var resolved: Result<Symbols, DisplayPowerError>?
    private let osMajorVersion: Int

    public init(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.osMajorVersion = osMajorVersion
    }

    /// Why the display is left alone on this Mac, or nil.
    public func refusal() -> String? {
        do { _ = try symbols(); return nil } catch { return error.localizedDescription }
    }

    public func readBrightness() throws -> Float {
        let s = try symbols()
        let display = try changeable(s)
        var value: Float = 0
        let rc = s.get(display, &value)
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesGetBrightness (\(rc))") }
        return value
    }

    public func setBrightness(_ value: Float) throws {
        let s = try symbols()
        let display = try changeable(s)
        let rc = s.set(display, min(max(value, 0), 1))
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesSetBrightness (\(rc))") }
    }

    public func requestSleep() {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != 0 else { return }
        defer { IOObjectRelease(wrangler) }
        _ = IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
    }

    public func wake() {
        var id: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("DarraOwl : capot ouvert" as CFString, kIOPMUserActiveLocal, &id)
    }

    public func isAsleep() -> Bool {
        CGDisplayIsAsleep(DisplayGuards.builtInDisplayID()) != 0
    }

    private func symbols() throws -> Symbols {
        if let resolved { return try resolved.get() }
        let result = Self.resolve(osMajorVersion: osMajorVersion)
        resolved = result
        return try result.get()
    }

    private static func resolve(osMajorVersion: Int) -> Result<Symbols, DisplayPowerError> {
        if let why = DisplayGuards.displayServicesRefusal(osMajorVersion: osMajorVersion) {
            return .failure(DisplayPowerError(what: why))
        }
        guard let handle = dlopen(path, RTLD_LAZY) else {
            return .failure(DisplayPowerError(what: "DisplayServices.framework introuvable"))
        }
        func symbol<T>(_ name: String) throws -> T {
            guard let p = dlsym(handle, name) else { throw DisplayPowerError(what: "DisplayServices n'a plus \(name)") }
            return unsafeBitCast(p, to: T.self)
        }
        do {
            return .success(Symbols(
                get: try symbol("DisplayServicesGetBrightness"),
                set: try symbol("DisplayServicesSetBrightness"),
                canChange: try symbol("DisplayServicesCanChangeBrightness")
            ))
        } catch {
            return .failure(error as? DisplayPowerError ?? DisplayPowerError(what: error.localizedDescription))
        }
    }

    private func changeable(_ s: Symbols) throws -> CGDirectDisplayID {
        let display = DisplayGuards.builtInDisplayID()
        guard s.canChange(display) else { throw DisplayPowerError(what: "luminosité non modifiable sur l'écran \(display)") }
        return display
    }
}

@objc protocol KeyboardBrightnessClientBridge: NSObjectProtocol {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
}

/// Private CoreBrightness.framework `KeyboardBrightnessClient`.
@MainActor
public final class CoreBrightnessKeyboard: KeyboardBacklighting {
    private static let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private var resolved: Result<any KeyboardBrightnessClientBridge, DisplayPowerError>?

    public init() {}

    public func refusal() -> String? {
        do { _ = try client(); return nil } catch { return error.localizedDescription }
    }

    public func readBrightness() throws -> Float? {
        let c = try client()
        guard let first = Self.builtIn(c).first else { return nil }
        return c.brightness(forKeyboard: first)
    }

    public func setBrightness(_ value: Float) throws {
        let c = try client()
        let ids = Self.builtIn(c)
        guard !ids.isEmpty else { return }
        for id in ids where !c.setBrightness(min(max(value, 0), 1), forKeyboard: id) {
            throw DisplayPowerError(what: "rétroéclairage du clavier \(id) refusé")
        }
    }

    private static func builtIn(_ c: any KeyboardBrightnessClientBridge) -> [UInt64] {
        ((c.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []).filter(c.isKeyboardBuiltIn)
    }

    private func client() throws -> any KeyboardBrightnessClientBridge {
        if let resolved { return try resolved.get() }
        let result = Self.resolve()
        resolved = result
        return try result.get()
    }

    /// Nothing is instantiated before the encodings were checked.
    private static func resolve() -> Result<any KeyboardBrightnessClientBridge, DisplayPowerError> {
        guard dlopen(path, RTLD_LAZY) != nil, let cls = NSClassFromString("KeyboardBrightnessClient") else {
            return .failure(DisplayPowerError(what: "CoreBrightness KeyboardBrightnessClient introuvable"))
        }
        if let why = DisplayGuards.keyboardClientRefusal(encodingFor: { name in
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)), let e = method_getTypeEncoding(m) else { return nil }
            return String(decoding: Data(bytes: e, count: strlen(e)), as: UTF8.self)
        }) {
            return .failure(DisplayPowerError(what: why))
        }
        guard let type = cls as? NSObject.Type else {
            return .failure(DisplayPowerError(what: "KeyboardBrightnessClient n'est pas un NSObject"))
        }
        return .success(unsafeBitCast(type.init(), to: (any KeyboardBrightnessClientBridge).self))
    }
}
