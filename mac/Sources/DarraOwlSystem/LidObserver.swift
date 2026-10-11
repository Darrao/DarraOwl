// Adapted from Insomnia (https://github.com/krishhgg/Insomnia), MIT License,
// Copyright (c) 2026 Krish Garg. See THIRD_PARTY_NOTICES.md.

import Foundation
import IOKit

/// IOKit interest notification on IOPMrootDomain. Nothing runs between
/// events. A change is delivered only if it still holds 2 s later.
@MainActor
public final class LidObserver {
    public static let debounce: TimeInterval = 2

    /// `true` for closed.
    public var onChange: ((Bool) -> Void)?
    public private(set) var isClosed = false

    private var pending: Bool?
    private var timer: Timer?
    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0

    public init() {}

    public func start() {
        guard port == nil else { return }
        isClosed = IOPSPowerSource.lidClosed() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(p, service, kIOGeneralInterest, Self.callback, refcon, &notification)
    }

    private static let callback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.handle() }
    }

    private func handle() {
        guard let now = IOPSPowerSource.lidClosed() else { return }
        guard now != isClosed else {
            pending = nil
            timer?.invalidate()
            return
        }
        guard pending != now else { return }
        pending = now
        timer?.invalidate()
        let t = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func settle() {
        guard let candidate = pending else { return }
        pending = nil
        guard IOPSPowerSource.lidClosed() == candidate, candidate != isClosed else { return }
        isClosed = candidate
        onChange?(candidate)
    }
}
