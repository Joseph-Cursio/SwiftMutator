import Foundation

/// How a baseline under xcodebuild's parallel testing spread its tests over the clones of the simulator, read from the
/// line it prints for each test that ends on one: `Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App
/// (123)' (0.010 seconds)`, or `failed on` or `skipped on`, as `SimulatorTrouble` reads for a failed test. It shows
/// whether one worker would gain by testing one test at a time on a simulator of its own
/// (`SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(_:)`).
struct ParallelTestingSpread: Equatable {
    /// How many clones ran tests: the different N of `Clone N of`. The process ID that follows the clone's name differs
    /// for each process a clone starts, so it doesn't count.
    let clones: Int
    /// What the tests' own seconds add up to, over every one of those clones. A line without them counts 0.
    let testSeconds: Double

    /// The spread of `baselineLog`'s tests on one device, or nil if it has no line for a test that ended on a clone, as
    /// a log of tests run one at a time has none. A test command with several `-destination`s tests on each, and each
    /// numbers its own clones, `Clone 1 of iPad Air - App (125)` as well as `Clone 1 of iPhone 17 Pro - App (123)`, but
    /// a mutant's run tests only on the first. So the device is the one named `deviceName`, the first destination's
    /// `name=`, when the log shows it, and otherwise the first the log shows.
    static func of(baselineLog: String, onDeviceNamed deviceName: String? = nil) -> ParallelTestingSpread? {
        var devices: [DeviceSpread] = []
        // "\r\n" is a single Character, so a log with those line breaks isn't split at "\n" alone.
        let lines = baselineLog.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for line in lines where line.hasPrefix("Test case '") {
            guard let (clone, device) = clone(endedOnBy: line) else {
                continue
            }
            let seconds = seconds(atTheEndOf: line)
            if let index = devices.firstIndex(where: { $0.device == device }) {
                devices[index].add(clone, seconds)
            } else {
                var spread = DeviceSpread(device: device)
                spread.add(clone, seconds)
                devices.append(spread)
            }
        }
        let named = deviceName.flatMap { name in
            devices.first { $0.device == name || $0.device.hasPrefix(name + " - ") }
        }
        return (named ?? devices.first).map {
            ParallelTestingSpread(clones: $0.clones.count, testSeconds: $0.testSeconds)
        }
    }

    /// The tests that ended on one device's clones, which `device` names as its clones' names do after `Clone N of `,
    /// such as `iPhone 17 Pro - App`, without the process ID.
    private struct DeviceSpread {
        let device: Substring
        private(set) var clones: Set<Int> = []
        private(set) var testSeconds = 0.0

        mutating func add(_ clone: Int, _ seconds: Double) {
            clones.insert(clone)
            testSeconds += seconds
        }
    }

    /// What follows a test's name on the line for a test that ended on a clone, up to the clone's number.
    private static let endings = ["' passed on 'Clone ", "' failed on 'Clone ", "' skipped on 'Clone "]

    /// The N of the `Clone N of <device> (<pid>)` that `line` says its test ended on, and the device, or nil if it
    /// says none.
    private static func clone(endedOnBy line: Substring) -> (number: Int, device: Substring)? {
        guard let onClone = endings.lazy.compactMap({ line.range(of: $0) }).first else {
            return nil
        }
        let rest = line[onClone.upperBound...]
        let number = rest.prefix { ("0"..."9").contains($0) }
        let separator = " of "
        guard let clone = Int(number), rest.dropFirst(number.count).hasPrefix(separator) else {
            return nil
        }
        var name = rest.dropFirst(number.count + separator.count)
        // The quote that closes the clone's name is the line's last, before any `(x seconds)`.
        if let close = name.lastIndex(of: "'") {
            name = name[..<close]
        }
        if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")"),
           name[open.upperBound...].dropLast().allSatisfy({ ("0"..."9").contains($0) }) {
            name = name[..<open.lowerBound]
        }
        return (clone, name)
    }

    /// The `x` of the `(x seconds)` that ends `line`, or 0.
    private static func seconds(atTheEndOf line: Substring) -> Double {
        let text = line.trimmingCharacters(in: .whitespaces)
        let suffix = " seconds)"
        guard text.hasSuffix(suffix), let open = text.range(of: "(", options: .backwards) else {
            return 0
        }
        return Double(text[open.upperBound...].dropLast(suffix.count)) ?? 0
    }
}
