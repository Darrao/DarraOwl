// Classification of the power source list adapted from Insomnia
// (https://github.com/krishhgg/Insomnia), MIT License, Copyright (c) 2026
// Krish Garg. See THIRD_PARTY_NOTICES.md.

import DarraOwlCore
import DarraOwlShared
import Foundation
import IOKit
import IOKit.ps

/// Battery level, charger and thermal state from IOKit and ProcessInfo. Cheap
/// enough to read on every check.
public struct IOPSPowerSource: PowerSourceReading {
    public init() {}

    public func read() -> PowerSnapshot {
        let (battery, external) = Self.readBattery()
        return PowerSnapshot(battery: battery, onExternalPower: external, thermal: Self.thermal())
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    static func readBattery() -> (BatteryStatus, Bool) {
        var sources: [[String: Any]]?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            sources = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        }
        for desc in sources ?? [] {
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { return (.unreadable, onAC || charging) }
            return (.percent(Int((Double(current) / Double(max) * 100).rounded())), onAC || charging)
        }
        // No battery entry: a desktop, or a laptop whose list failed. On such
        // a laptop an unknown charger state counts as battery, so the floor
        // rules end the session rather than run blind.
        guard hasBatteryService() else { return (.none, true) }
        return (.unreadable, externalPowerConnected() ?? false)
    }

    static func hasBatteryService() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    static func externalPowerConnected() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
}
