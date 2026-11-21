@testable import muterCore
import XCTest

/// #262: each key flag in place of its key, but `--exclude-calls`, which adds to it, and nothing else changed.
final class KeyFlagsTests: XCTestCase {
    /// Each flag at a value `configurationWithEveryFieldSet()` doesn't hold, and the key it changes.
    private static let eachFlag: [(flags: KeyFlags, key: String)] = [
        (KeyFlags(excludeCalls: ["log"]), "excludeCalls"),
        (KeyFlags(coverageThreshold: 20), "coverageThreshold"),
        (KeyFlags(buildSystem: .xcodebuild), "buildSystem"),
        (KeyFlags(stopAtFirstFailure: .enabled), "stopAtFirstFailure"),
        (KeyFlags(workersShareBuild: .enabled), "workersShareBuild"),
        (KeyFlags(oneWorkerSimulator: .disabled), "oneWorkerSimulator"),
        (KeyFlags(suspectTestFilePercent: 40), "suspectTestFilePercent"),
        (KeyFlags(suspectTestMinimumFiles: 7), "suspectTestMinimumFiles"),
        (KeyFlags(controlRunEvery: 0), "controlRunEvery"),
        (KeyFlags(suspectKillReruns: 0), "suspectKillReruns"),
        (KeyFlags(keepAllLogs: .disabled), "keepAllLogs"),
        (KeyFlags(keepLogFolders: 5), "keepLogFolders"),
        (KeyFlags(keepSwiftLintPhases: .disabled), "keepSwiftLintPhases"),
        (KeyFlags(propertyTestFilter: ["Laws"]), "propertyTestFilter"),
        (KeyFlags(propertySurvivorReruns: 3), "propertySurvivorReruns"),
        (KeyFlags(propertySurvivorRerunLimit: 9), "propertySurvivorRerunLimit"),
    ]

    // Each flag changes its own key, as a results header records it, and no other.
    func test_eachFlag_changesItsKeyAlone() {
        let base = configurationWithEveryFieldSet()
        let before = ResumeCheck.values(of: base)

        for (flags, key) in Self.eachFlag {
            let after = ResumeCheck.values(of: base.overriding(workers: nil, timeout: nil, keys: flags))
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            XCTAssertEqual(changed, [key], "\(flags)")
        }
        XCTAssertEqual(Set(Self.eachFlag.map(\.key)).count, 16)
    }

    // As --exclude adds to exclude: exclusions accumulate.
    func test_excludeCalls_addsAfterTheKeysEntries() {
        let base = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], excludeCallList: ["print"])

        let overridden = base.overriding(workers: nil, timeout: nil, keys: KeyFlags(excludeCalls: ["log", "trace"]))

        XCTAssertEqual(overridden.excludeCallList, ["print", "log", "trace"])
    }

    // A `--no-` flag turns a key on in the file off, and the plain one turns it on; neither leaves the key.
    func test_aPair_setsItsSwitch_orLeavesIt() {
        let base = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: .enabled)

        XCTAssertEqual(base.withKeyFlags(KeyFlags(keepAllLogs: .disabled)).keepAllLogs, .disabled)
        XCTAssertEqual(MuterConfiguration().withKeyFlags(KeyFlags(keepAllLogs: .enabled)).keepAllLogs, .enabled)
        XCTAssertEqual(base.withKeyFlags(KeyFlags()).keepAllLogs, .enabled)
        XCTAssertEqual(ConfigurationSwitch.given(true), .enabled)
        XCTAssertEqual(ConfigurationSwitch.given(false), .disabled)
        XCTAssertEqual(ConfigurationSwitch.given(nil), .unset)
    }

    func test_noFlag_changesNothing() {
        let base = configurationWithEveryFieldSet()

        XCTAssertEqual(base.overriding(workers: nil, timeout: nil, keys: KeyFlags()), base)
    }
}
