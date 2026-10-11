import Darwin

/// Locks the session now with login.framework's SACLockScreenImmediate, the
/// call behind "Lock Screen" in the Apple menu. Private: looked up at run
/// time, so a macOS without it only makes `lockNow()` return false.
public enum ScreenLock {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let function: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    public static var isAvailable: Bool { function != nil }

    @discardableResult
    public static func lockNow() -> Bool {
        guard let function else { return false }
        return function() == 0
    }
}
