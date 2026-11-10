@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

extension RemoveSideEffectsOperatorTests {
    // Removing a call on a lock can leave a later call waiting for good, which ends as a timeout. Only four types
    // were known, by a variable made before its use and called by its bare name.
    func test_neverRemovesACallOnALock() throws {
        let removed = try removedStatements(
            in: """
            final class Store {
                func update() {
                    self.lock.lock()
                    write()
                    lock.unlock()
                    semaphore.signal()
                    group.enter()
                    queue.async { self.group.leave() }
                    os_unfair_lock_lock(&unfair)
                    os_unfair_lock_unlock(&unfair)
                    _ = waiter?.wait(timeout: .now())
                    allocated.lock()
                    counter.withLock { $0 += 1 }
                }

                private let lock = NSLock()
                private let semaphore: DispatchSemaphore
                private let group = Foundation.DispatchGroup()
                private var unfair = os_unfair_lock()
                private var waiter: DispatchSemaphore?
                private let allocated = OSAllocatedUnfairLock()
                private let counter = Mutex(0)
            }
            """
        )

        XCTAssertEqual(removed, ["write()", "counter.withLock { $0 += 1 }"])
    }

    // A lock is known by its initializer though its annotation names a protocol, by a generic type, as a static
    // property called after `Self.` or its type, and as a parameter. `withLock` takes no lock that removing it leaves
    // taken, so it's removed, as `Mutex`'s is.
    func test_neverRemovesACallOnALock_declaredOrCalledAnyOtherWay() throws {
        let removed = try removedStatements(
            in: """
            final class Cache {
                private let lock: NSLocking = NSRecursiveLock()
                private let unfair: OSAllocatedUnfairLock<Void>
                private let made = OSAllocatedUnfairLock<()>()
                private static let shared = NSLock()
                private let ready: Optional<DispatchSemaphore> = nil

                func update(_ group: DispatchGroup) {
                    lock.lock()
                    unfair.unlock()
                    made.lock()
                    Self.shared.lock()
                    Cache.shared.unlock()
                    group.leave()
                    ready?.signal()
                    run { (done: DispatchSemaphore) in done.signal() }
                    lock.withLock { store() }
                }
            }
            """
        )

        XCTAssertEqual(removed, ["lock.withLock { store() }"])
    }

    // A lock's method passed by name runs later, as `group.leave` does once the work is done.
    func test_neverRemovesALocksMethodPassedByName() throws {
        let removed = try removedStatements(
            in: """
            final class Loader {
                private let group = DispatchGroup()

                func load() {
                    queue.async(execute: group.leave)
                    queue.async(execute: refresh)
                    actions.append(self.group.leave)
                    handlers.append(contentsOf: [group.leave])
                    register(group.debugDescription)
                    print2("\\(self.group.hash)")
                }
            }
            """
        )

        XCTAssertEqual(removed, [
            "queue.async(execute: refresh)", "register(group.debugDescription)", "print2(\"\\(self.group.hash)\")",
        ])
    }
}
