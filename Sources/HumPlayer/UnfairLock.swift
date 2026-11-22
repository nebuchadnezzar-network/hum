import Foundation
import os

/// `os_unfair_lock` with a Swift-shaped API.
///
/// The pointer indirection is required: `os_unfair_lock_t` must point at stable
/// memory, and a struct stored in a Swift property can be moved by the compiler.
public final class UnfairLock {
    private let pointer: os_unfair_lock_t

    public init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    public func lock() { os_unfair_lock_lock(pointer) }
    public func unlock() { os_unfair_lock_unlock(pointer) }

    @discardableResult
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
