// Adapted from Insomnia (https://github.com/krishhgg/Insomnia), MIT License,
// Copyright (c) 2026 Krish Garg. See THIRD_PARTY_NOTICES.md.

import AudioToolbox
import CoreAudio
import DarraOwlCore
import Foundation

public struct AudioControlError: Error, LocalizedError, Sendable {
    let what: String
    let status: OSStatus
    public var errorDescription: String? { "\(what) (OSStatus \(status))" }
}

/// Volume and mute of output devices, addressed by their stable UID so lid
/// open restores the device lid close muted even if the default output
/// changed meanwhile.
@MainActor
public final class CoreAudioControl: AudioControlling {
    public init() {}

    public func readDefaultOutput() throws -> AudioOutput {
        try output(of: defaultOutputDevice())
    }

    public func mute(deviceUID: String) throws {
        var m: UInt32 = 1
        try set(try device(withUID: deviceUID), Self.muteAddress, &m, "couper le son")
    }

    public func apply(volume: Float, muted: Bool, deviceUID: String) throws {
        let d = try device(withUID: deviceUID)
        var v = Float32(min(max(volume, 0), 1))
        try set(d, Self.volumeAddress, &v, "volume")
        var m: UInt32 = muted ? 1 : 0
        try set(d, Self.muteAddress, &m, "sourdine")
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private func output(of device: AudioObjectID) throws -> AudioOutput {
        var volume: Float32 = 0
        try get(device, Self.volumeAddress, &volume, "lire le volume")
        var muted: UInt32 = 0
        try get(device, Self.muteAddress, &muted, "lire la sourdine")
        return AudioOutput(
            deviceUID: try string(kAudioDevicePropertyDeviceUID, of: device),
            name: try? string(kAudioObjectPropertyName, of: device),
            volume: Float(volume),
            muted: muted != 0
        )
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw AudioControlError(what: "sortie audio par défaut", status: status) }
        return device
    }

    private func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        guard status == noErr, let s = value?.takeRetainedValue() else { throw AudioControlError(what: "propriété audio", status: status) }
        return s as String
    }

    /// Only `kAudioObjectUnknown` counts as "not connected"; a failed lookup
    /// is an error of its own, so a device is never reported gone by mistake.
    private func device(withUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr else { throw AudioControlError(what: "recherche de la sortie audio", status: status) }
        guard device != kAudioObjectUnknown else { throw AudioDeviceMissing(deviceUID: uid) }
        return device
    }

    private func get<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }

    private func set<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T, _ what: String) throws {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &addr, 0, nil, size, UnsafeRawPointer($0)) }
        guard status == noErr else { throw AudioControlError(what: what, status: status) }
    }
}
