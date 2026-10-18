import Foundation

/// Small mutable-state holder for the classic `Process` + `Pipe` pattern,
/// where a `readabilityHandler` closure and a `terminationHandler` closure
/// both need to touch the same state from different queues. Swift's strict
/// concurrency checking can't prove that's safe on its own, so we make it
/// actually safe with a lock and tell the compiler to trust it.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
