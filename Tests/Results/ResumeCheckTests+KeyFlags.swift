@testable import muterCore
import XCTest

/// #262: a key's flag is recorded in the key's place, so a resume compares it as it does the key.
extension ResumeCheckTests {
    private static let recordedKeys = MuterConfiguration(
        executable: "/usr/bin/swift", arguments: ["test"], excludeCallList: ["print"], suspectKillReruns: 25
    )

    private func verdict(resumingWith flags: KeyFlags) -> ResumeCheck.Verdict {
        let resolved = Self.recordedKeys.overriding(workers: nil, timeout: nil, keys: flags)
        return check(current(configuration: resolved), recorded: header(of: current(configuration: Self.recordedKeys)))
    }

    // As a change of the key would be, in the file.
    func test_aFlagThatChangesAComparedKey_refusesTheResume() {
        let refused: [(flags: KeyFlags, key: String)] = [
            (KeyFlags(excludeCalls: ["log"]), "excludeCalls"),
            (KeyFlags(coverageThreshold: 40), "coverageThreshold"),
            (KeyFlags(buildSystem: .swift), "buildSystem"),
        ]
        for (flags, key) in refused {
            let result = verdict(resumingWith: flags)

            XCTAssertEqual(result.refusals.compactMap(configurationKey), [key], "\(flags)")
            XCTAssertEqual(result.notices, [], "\(flags)")
        }
    }

    // A key no result depends on is only said, flag or not.
    func test_aFlagThatChangesAKeyNoResultDependsOn_isOnlySaid() {
        let result = verdict(resumingWith: KeyFlags(suspectKillReruns: 5, keepAllLogs: .enabled))

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.notices, [
            "keepAllLogs was not set and is true now, which no result depends on.",
            "suspectKillReruns was 25 and is 5 now, which no recorded result depends on, though it chooses which "
                + "kills are tested again alone.",
        ])
    }

    // A flag that gives the key's own value is no change.
    func test_aFlagThatGivesTheKeysValue_isNoDifference() {
        let result = verdict(resumingWith: KeyFlags(suspectKillReruns: 25))

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.notices, [])
    }

    // `--exclude-calls` adds to `excludeCalls`, whose entries choose the same calls in any order, once each, as
    // `--exclude`'s choose the same files: naming the key's own entry again, or moving an entry between the key and
    // the flag, is no change.
    func test_excludeCallsEntriesRepeatedOrMoved_areNoDifference() {
        let result = verdict(resumingWith: KeyFlags(excludeCalls: ["print"]))

        XCTAssertEqual(result.refusals, [])
        XCTAssertEqual(result.notices, [])

        let keyAThenFlagB = MuterConfiguration(executable: "/swift", arguments: [], excludeCallList: ["a"])
            .overriding(workers: nil, timeout: nil, keys: KeyFlags(excludeCalls: ["b"]))
        let keyBThenFlagA = MuterConfiguration(executable: "/swift", arguments: [], excludeCallList: ["b"])
            .overriding(workers: nil, timeout: nil, keys: KeyFlags(excludeCalls: ["a"]))
        XCTAssertEqual(ResumeCheck.configurationDifferences(keyAThenFlagB, keyBThenFlagA), [])
    }
}
