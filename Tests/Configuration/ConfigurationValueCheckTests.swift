@testable import muterCore
import Rainbow
import XCTest

/// Keys SwiftMutator doesn't know, and values of the wrong type or out of range (#122): each was ignored or taken as a
/// default without a word.
final class ConfigurationValueCheckTests: MuterTestCase {
    private let swiftTest = "executable: /usr/bin/swift\narguments: [test]"

    // MARK: Values of the wrong type

    // One string, not a list, excluded nothing.
    func test_anExcludeThatIsOneString_isRefused_namingTheKey() {
        assertRefused("\(swiftTest)\nexclude: Sources/Generated", saying: [
            "exclude must be a list of paths or globs",
            "not Sources/Generated",
        ])
    }

    func test_excludeCallsThatIsOneString_isRefused() {
        assertRefused("\(swiftTest)\nexcludeCalls: log", saying: ["excludeCalls must be a list of function names"])
    }

    func test_aCoverageThresholdThatIsNotANumber_isRefused() {
        assertRefused("\(swiftTest)\ncoverageThreshold: half", saying: ["coverageThreshold must be a number, not half"])
    }

    func test_aTimeoutThatIsNotANumber_isRefused() {
        assertRefused("\(swiftTest)\nmutationTestTimeout: 2m", saying: ["mutationTestTimeout must be a number, not 2m"])
    }

    // It became `unknown`, so a wrapper script got no SwiftPM handling.
    func test_aBuildSystemThatIsNeitherSwiftNorXcodebuild_isRefused() {
        assertRefused("\(swiftTest)\nbuildSystem: spm", saying: ["buildSystem must be swift or xcodebuild, not spm"])
        assertRefused("\(swiftTest)\nbuildSystem: [swift]", saying: ["buildSystem must be swift or xcodebuild"])
    }

    func test_blankListsAndBuildSystem_areUnset() throws {
        let configuration = try MuterConfiguration(
            from: Data("\(swiftTest)\nexclude:\nexcludeCalls:\nbuildSystem:\n".utf8)
        )

        XCTAssertEqual(configuration.excludeFileList, [])
        XCTAssertEqual(configuration.excludeCallList, [])
        XCTAssertNil(configuration.explicitBuildSystem)
    }

    // What a results file's header, or a baseline file, holds where an earlier version took another value as
    // `unknown`, then went by `executable`'s name: as unset, so a configuration without the key resumes that run.
    func test_buildSystemUnknown_isUnset_asAnEarlierVersionWroteIt() throws {
        let yaml = try MuterConfiguration(from: Data("\(swiftTest)\nbuildSystem: unknown".utf8))
        let json = try JSONDecoder().decode(
            MuterConfiguration.self,
            from: Data(#"{"executable":"/s","arguments":[],"buildSystem":"unknown","coverageThreshold":0}"#.utf8)
        )
        let baseline = BaselineScope.Configuration(arguments: ["test"], buildSystem: "unknown")

        XCTAssertNil(yaml.explicitBuildSystem)
        XCTAssertNil(json.explicitBuildSystem)
        XCTAssertNil(baseline.asMuterConfiguration.explicitBuildSystem)
        XCTAssertEqual(
            ResumeCheck.configurationDifferences(json, MuterConfiguration(executable: "/s", arguments: [])),
            []
        )
    }

    // An earlier version took them, and recorded them in a results file's header, which a resume, a merge and
    // `report` must still read: their range is checked only for a run's own configuration.
    func test_valuesOutOfRange_stillParse_asAnEarlierVersionsHeaderHoldsThem() throws {
        let json = #"{"executable":"/s","arguments":[],"coverageThreshold":150,"mutationTestTimeout":0,"#
            + #""buildTimeout":-5,"mutationTestWorkers":0}"#

        let configuration = try JSONDecoder().decode(MuterConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.coverageThreshold, 150)
        XCTAssertEqual(configuration.testSuiteTimeout, 0)
        XCTAssertEqual(configuration.buildTimeout, -5)
        XCTAssertEqual(configuration.mutationTestWorkers, 0)
    }

    func test_whatEncodingWrites_parsesBack() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            excludeList: ["Generated"],
            excludeCallList: ["log"],
            coverageThreshold: 12.5,
            testSuiteTimeOut: 30,
            buildSystem: .swift
        )

        XCTAssertEqual(try MuterConfiguration(from: configuration.asData), configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(MuterConfiguration.self, from: JSONEncoder().encode(configuration)),
            configuration
        )
    }

    // MARK: Values out of range

    func test_valuesOutOfRange_areRefused_namingTheKey() {
        let seconds = "must be a number of seconds above 0, and at most a day (86400), not"
        let cases: [(MuterConfiguration, String)] = [
            (.init(testSuiteTimeOut: 0), "mutationTestTimeout \(seconds) 0."),
            (.init(testSuiteTimeOut: -5), "mutationTestTimeout \(seconds) -5."),
            (.init(testSuiteTimeOut: 86_401), "mutationTestTimeout \(seconds) 86401."),
            // As written, not rounded to a value in range, as `%g` would show it.
            (.init(testSuiteTimeOut: 86_400.01), "mutationTestTimeout \(seconds) 86400.01."),
            (.init(testSuiteTimeOut: 1_000_000), "mutationTestTimeout \(seconds) 1000000."),
            (.init(testSuiteTimeOut: .nan), "mutationTestTimeout \(seconds) nan."),
            (.init(buildTimeout: 0), "buildTimeout \(seconds) 0."),
            (.init(mutationTestWorkers: 0), "mutationTestWorkers must be a whole number, at least 1, not 0."),
            (.init(mutationTestWorkers: -2), "mutationTestWorkers must be a whole number, at least 1, not -2."),
            (.init(coverageThreshold: 150), "coverageThreshold must be a percentage from 0 to 100, not 150."),
            (.init(coverageThreshold: -1), "coverageThreshold must be a percentage from 0 to 100, not -1."),
            (.init(coverageThreshold: 100.00001), "coverageThreshold must be a percentage from 0 to 100, not 100.00001."
            ),
        ]

        for (configuration, reason) in cases {
            XCTAssertEqual(LoadConfiguration.valueOutOfRange(in: configuration), reason)
        }
    }

    func test_valuesAtTheirBounds_areTaken() {
        let configurations: [MuterConfiguration] = [
            .init(),
            .init(coverageThreshold: 0, testSuiteTimeOut: 86_400, mutationTestWorkers: 1, buildTimeout: 0.5),
            .init(coverageThreshold: 100, testSuiteTimeOut: 0.1, buildSystem: .swift),
            .init(buildSystem: .xcodebuild),
        ]

        for configuration in configurations {
            XCTAssertNil(LoadConfiguration.valueOutOfRange(in: configuration), "\(configuration)")
        }
    }

    // MARK: Unknown keys

    func test_unknownKeys_areFound_inTheOrderWritten_withTheKeyMeant() {
        let yaml = """
        \(swiftTest)
        mutationTestTimeOut: 120
        exlude: [Generated]
        fail-under: 80
        workers: 4
        timeout: 60
        colour: blue
        coverageThreshold: 10
        """

        XCTAssertEqual(UnknownConfigurationKey.found(in: Data(yaml.utf8)), [
            .init(key: "mutationTestTimeOut", closest: "mutationTestTimeout"),
            .init(key: "exlude", closest: "exclude"),
            .init(key: "fail-under", closest: "failUnder"),
            .init(key: "workers", closest: "mutationTestWorkers"),
            // The flag's name: `--timeout` sets `mutationTestTimeout`.
            .init(key: "timeout", closest: "mutationTestTimeout"),
            .init(key: "colour", closest: nil),
        ])
    }

    func test_unknownKeys_areFound_inALegacyJSONFile() {
        let json = #"{"executable": "/usr/bin/swift", "arguments": ["test"], "excludeList": []}"#

        XCTAssertEqual(UnknownConfigurationKey.found(in: Data(json.utf8)), [
            .init(key: "excludeList", closest: "exclude"),
        ])
    }

    func test_noKeyIsUnknown_inWhatEncodingWrites_norInWhatIsNotAMapping() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 30,
            buildSystem: .swift,
            mutationTestWorkers: 2,
            failUnder: 80,
            operators: [.swapTernary],
            reports: [ReportRequest(format: .markdown, path: "summary.md")]
        )

        XCTAssertEqual(UnknownConfigurationKey.found(in: try configuration.asData), [])
        XCTAssertEqual(UnknownConfigurationKey.found(in: Data("[a, b]".utf8)), [])
        XCTAssertEqual(UnknownConfigurationKey.found(in: Data("key: [".utf8)), [])
    }

    // The merged keys are read as the file's own, so they are checked, and `<<` is no key.
    func test_aMergeKeysMappings_areChecked_inItsPlace() {
        let yaml = """
        common: &common
          executable: /usr/bin/swift
          arguments: [test]
          mutationTestTimeOut: 120
        <<: *common
        extra: &extra {workers: 2}
        more:
          <<: [*extra]
        """

        XCTAssertEqual(
            UnknownConfigurationKey.found(in: Data(yaml.utf8)).map(\.key),
            ["common", "mutationTestTimeOut", "extra", "more"]
        )
        XCTAssertEqual(
            UnknownConfigurationKey.found(in: Data("a: &a {x: 1}\nb: &b {y: 2}\n<<: [*a, *b]\n".utf8)).map(\.key),
            ["a", "b", "x", "y"]
        )
    }

    // A key that shares a start with another isn't taken for it when what follows differs throughout: following the
    // hint would move paths into `excludeCalls`, which takes any strings, and exclude nothing.
    func test_closest_isNotAKeyThatOnlySharesAStart() {
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludeFiles"), "exclude")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludePaths"), "exclude")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludePath"), "exclude")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludeFunctions"), "excludeCalls")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludeMethods"), "excludeCalls")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "report"), "reports")
    }

    func test_closest_needsAFewEditsAtMost_forItsLength() {
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excludeCall"), "excludeCalls")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "excldue"), "exclude")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "executible"), "executable")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "suspectKillRerun"), "suspectKillReruns")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "BUILD_TIMEOUT"), "buildTimeout")
        XCTAssertEqual(UnknownConfigurationKey.closest(to: "coverage"), "coverageThreshold")
        XCTAssertNil(UnknownConfigurationKey.closest(to: "abc"))
        XCTAssertNil(UnknownConfigurationKey.closest(to: "---"))
        XCTAssertNil(UnknownConfigurationKey.closest(to: "verbose"))
    }

    func test_theLogger_namesEachUnknownKey_andTheKeyMeant() {
        Logger().configurationKeysUnknown(
            [.init(key: "mutationTestTimeOut", closest: "mutationTestTimeout"), .init(key: "colour", closest: nil)],
            file: "muter.conf.yml"
        )

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ muter.conf.yml: \("mutationTestTimeOut".bold) isn't a configuration key, so it is ignored. "
                + "Did you mean \("mutationTestTimeout".bold)?",
            "⚠️ muter.conf.yml: \("colour".bold) isn't a configuration key, so it is ignored.",
        ])
    }

    private func assertRefused(_ yaml: String, saying parts: [String], line: UInt = #line) {
        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)), line: line) { error in
            for part in parts {
                XCTAssertTrue("\(error)".contains(part), "\(error)", line: line)
            }
        }
    }
}
