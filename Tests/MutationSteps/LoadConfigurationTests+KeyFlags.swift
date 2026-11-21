@testable import muterCore
import XCTest

/// #262: the flags of the keys that had none, put in place of their keys as the configuration is loaded, before
/// anything reads them.
extension LoadConfigurationTests {
    private static let everyKeyFlaggedKey = """
    executable: /usr/bin/swift
    arguments: [test]
    excludeCalls: [print]
    coverageThreshold: 80
    buildSystem: swift
    stopAtFirstFailure: false
    workersShareBuild: false
    oneWorkerSimulator: true
    suspectTestFilePercent: 30
    suspectTestMinimumFiles: 5
    controlRunEvery: 50
    suspectKillReruns: 25
    keepAllLogs: true
    keepLogFolders: 3
    keepSwiftLintPhases: true
    propertyTests: ["*Properties*"]
    propertyTestFilter: [Properties]
    propertySurvivorReruns: 10
    propertySurvivorRerunLimit: 50

    """

    // Each in place of its key, which the header then records and a resume compares; `--exclude-calls` after the
    // key's entries, as `--exclude` adds to `exclude`.
    func test_eachKeyFlag_replacesItsKey_andExcludeCallsAddsToIt() async throws {
        let flags = KeyFlags(
            excludeCalls: ["log"], coverageThreshold: 20, buildSystem: .swift, stopAtFirstFailure: .enabled,
            workersShareBuild: .enabled, oneWorkerSimulator: .disabled, suspectTestFilePercent: 40,
            suspectTestMinimumFiles: 7, controlRunEvery: 0, suspectKillReruns: 0, keepAllLogs: .disabled,
            keepLogFolders: 5, keepSwiftLintPhases: .disabled, propertyTestFilter: ["Laws"],
            propertySurvivorReruns: 3, propertySurvivorRerunLimit: 9
        )

        let configuration = try await loadedWithKeyFlags(Self.everyKeyFlaggedKey, flags)

        XCTAssertEqual(configuration.excludeCallList, ["print", "log"])
        XCTAssertEqual(configuration.coverageThreshold, 20)
        XCTAssertEqual(configuration.explicitBuildSystem, .swift)
        XCTAssertEqual(configuration.stopAtFirstFailure, .enabled)
        XCTAssertEqual(configuration.workersShareBuild, .enabled)
        XCTAssertEqual(configuration.oneWorkerSimulator, .disabled)
        XCTAssertEqual(configuration.suspectTestFilePercent, 40)
        XCTAssertEqual(configuration.suspectTestMinimumFiles, 7)
        XCTAssertEqual(configuration.controlRunEvery, 0)
        XCTAssertEqual(configuration.suspectKillReruns, 0)
        XCTAssertEqual(configuration.keepAllLogs, .disabled)
        XCTAssertEqual(configuration.keepLogFolders, 5)
        XCTAssertEqual(configuration.keepSwiftLintPhases, .disabled)
        XCTAssertEqual(configuration.propertyTestFilter, ["Laws"])
        XCTAssertEqual(configuration.propertySurvivorReruns, 3)
        XCTAssertEqual(configuration.propertySurvivorRerunLimit, 9)
    }

    func test_withoutKeyFlags_theKeysStand() async throws {
        let configuration = try await loadedWithKeyFlags(Self.everyKeyFlaggedKey, KeyFlags())

        XCTAssertEqual(configuration.excludeCallList, ["print"])
        XCTAssertEqual(configuration.coverageThreshold, 80)
        XCTAssertEqual(configuration.keepAllLogs, .enabled)
        XCTAssertEqual(configuration.controlRunEvery, 50)
        XCTAssertEqual(configuration.propertyTestFilter, ["Properties"])
    }

    // The flag takes its place, so the run never uses it, as for --build-timeout.
    func test_aCoverageThresholdOutOfRange_isLetThrough_whenTheFlagReplacesIt() async throws {
        let yaml = "executable: /usr/bin/swift\narguments: [test]\ncoverageThreshold: 150\n"

        let configuration = try await loadedWithKeyFlags(yaml, KeyFlags(coverageThreshold: 50))

        XCTAssertEqual(configuration.coverageThreshold, 50)
        await assertKeyFlagsRefused(yaml, KeyFlags(), "coverageThreshold must be a percentage from 0 to 100, not 150.")
    }

    // In place before the xcodebuild options are merged, which a wrapper script gets only as xcodebuild's.
    func test_buildSystemFlag_comesBeforeTheXcodebuildOptions() async throws {
        let wrapper = "executable: /usr/local/bin/run-tests.sh\narguments: [test]\nscheme: App\ndestination: id=1\n"
        await assertKeyFlagsRefused(
            wrapper,
            KeyFlags(),
            "`scheme:` is for an xcodebuild project, and `executable` isn't xcodebuild: set `buildSystem: xcodebuild` "
                + "if it runs xcodebuild."
        )

        let merged = try await loadedWithKeyFlags(wrapper, KeyFlags(buildSystem: .xcodebuild))

        XCTAssertEqual(merged.testCommandArguments, ["-scheme", "App", "-destination", "id=1", "test"])
        XCTAssertEqual(merged.buildSystem, .xcodebuild)
        await assertKeyFlagsRefused(
            "executable: /usr/bin/xcodebuild\narguments: [-destination, id=1, test]\nscheme: App\n",
            KeyFlags(buildSystem: .swift),
            "`scheme:` is for an xcodebuild project: `swift test` has no scheme, destination, workspace or project."
        )
    }

    // And before the checks of xcodebuild's arguments, which a wrapper script's get only as xcodebuild's.
    func test_buildSystemFlag_comesBeforeTheArgumentChecks() async throws {
        let wrapper = "executable: /usr/local/bin/run-tests.sh\narguments: [build-for-testing]\n"
        _ = try await loadedWithKeyFlags(wrapper, KeyFlags())

        await assertKeyFlagsRefused(wrapper, KeyFlags(buildSystem: .xcodebuild)) { reason in
            reason.hasPrefix("`build-for-testing` in `arguments` is an action SwiftMutator runs itself")
        }
    }

    // A run with no configuration file takes the flag too, and the header records it.
    func test_buildSystemFlag_replacesTheWorkedOutOnes() async throws {
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["Package.swift", "Sources"]
        process.stdoutToBeReturned = "/usr/bin/swift"
        state.runOptions = .make(keyFlags: KeyFlags(buildSystem: .swift, keepAllLogs: .enabled))

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertTrue(configuration.workedOut)
        XCTAssertEqual(configuration.explicitBuildSystem, .swift)
        XCTAssertEqual(configuration.keepAllLogs, .enabled)
    }

    // The rules between the keys hold whichever gives each value, the flag or the key.
    func test_thePropertyRerunRules_applyToTheFlags() async throws {
        let swift = "executable: /usr/bin/swift\narguments: [test]\n"
        await assertKeyFlagsRefused(
            swift,
            KeyFlags(propertySurvivorReruns: 3),
            "propertySurvivorReruns (or --property-survivor-reruns) needs propertyTestFilter or "
                + "--property-test-filter, which selects the property tests to run again"
        )
        await assertKeyFlagsRefused(
            swift,
            KeyFlags(propertyTestFilter: ["Laws"]),
            "propertyTestFilter (or --property-test-filter) needs propertyTests or --property-tests too, which "
                + "say which of a kill's recorded tests are property tests"
        )
        await assertKeyFlagsRefused(
            "executable: /usr/local/bin/run-tests.sh\narguments: [test]\npropertyTests: [\"*Law*\"]\n",
            KeyFlags(propertyTestFilter: ["Laws"]),
            "propertyTestFilter (or --property-test-filter) needs a SwiftPM or xcodebuild project, whose test "
                + "command it can filter"
        )

        let fromBoth = try await loadedWithKeyFlags(
            swift + "propertyTests: [\"*Law*\"]\npropertyTestFilter: [Laws]\n", KeyFlags(propertySurvivorReruns: 3)
        )
        XCTAssertEqual(fromBoth.propertySurvivorReruns, 3)
        let fromFlags = try await loadedWithKeyFlags(
            swift + "propertyTests: [\"*Law*\"]\n", KeyFlags(propertyTestFilter: ["Laws"], propertySurvivorReruns: 3)
        )
        XCTAssertEqual(fromFlags.propertyTestFilter, ["Laws"])
    }

    private func loadedWithKeyFlags(
        _ yaml: String,
        _ flags: KeyFlags,
        line: UInt = #line
    ) async throws -> MuterConfiguration {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(yaml.utf8)
        state.runOptions = .make(keyFlags: flags)
        let result = try await sut.run(with: state)
        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)", line: line)
            throw MuterError.literal(reason: "no configuration")
        }
        return configuration
    }

    private func assertKeyFlagsRefused(
        _ yaml: String,
        _ flags: KeyFlags,
        _ reason: String,
        line: UInt = #line
    ) async {
        await assertKeyFlagsRefused(yaml, flags, line: line) { refusal in
            XCTAssertEqual(refusal, reason, line: line)
            return refusal == reason
        }
    }

    private func assertKeyFlagsRefused(
        _ yaml: String,
        _ flags: KeyFlags,
        line: UInt = #line,
        where matches: (String) -> Bool
    ) async {
        do {
            _ = try await loadedWithKeyFlags(yaml, flags, line: line)
            XCTFail("\(yaml) with \(flags) wasn't refused", line: line)
        } catch let MuterError.configurationParsingError(refusal) {
            XCTAssertTrue(matches(refusal), refusal, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}
