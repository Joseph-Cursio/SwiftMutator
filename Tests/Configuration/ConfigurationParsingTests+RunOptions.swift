@testable import muterCore
import XCTest
import Yams

extension ConfigurationParsingTests {
    func test_parsePropertyTestFilter_andWhenItCanBeUsed() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let parsed = { (lines: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(lines)".utf8)) }

        let set = try parsed("propertyTests: ['*Properties*']\npropertyTestFilter: [SortProperties, ParseProperties]")
        XCTAssertEqual(set.propertyTestFilter, ["SortProperties", "ParseProperties"])
        XCTAssertNil(set.propertyRerunsUnsupportedReason)
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set, "written back as it was")
        XCTAssertThrowsError(try parsed("propertyTestFilter: ['']"))
        XCTAssertNil(try MuterConfiguration(from: Data(swiftTest.utf8)).propertyTestFilter)

        let withoutGlobs = try parsed("propertyTestFilter: [SortProperties]")
        XCTAssertEqual(
            withoutGlobs.propertyRerunsUnsupportedReason,
            "propertyTestFilter needs propertyTests too, which say which of a kill's recorded tests are property tests"
        )
        XCTAssertNil(withoutGlobs.withPropertyTestFilter())
        let wrapper = MuterConfiguration(
            executable: "/project/test.sh", arguments: [], propertyTests: ["*"], propertyTestFilter: ["Properties"]
        )
        XCTAssertEqual(
            wrapper.propertyRerunsUnsupportedReason,
            "propertyTestFilter needs a SwiftPM or xcodebuild project, whose test command it can filter"
        )
        XCTAssertNil(MuterConfiguration().withPropertyTestFilter(), "no filter, no filtered runs")
    }

    // Runs for each survivor, off by default, and the most survivors, 100 by default; each needs propertyTestFilter.
    func test_parsePropertySurvivorReruns_andWhenItCanBeUsed() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let parsed = { (lines: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(lines)".utf8)) }
        let filter = "propertyTests: ['*Properties*']\npropertyTestFilter: [SortProperties]"

        let set = try parsed("\(filter)\npropertySurvivorReruns: 10\npropertySurvivorRerunLimit: 20")
        XCTAssertEqual([set.runsForEachSurvivor, set.survivorsToTestAgain], [10, 20])
        XCTAssertNil(set.propertySurvivorRerunsUnsupportedReason)
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set, "written back as it was")

        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))
        XCTAssertEqual([unset.runsForEachSurvivor, unset.survivorsToTestAgain], [0, 100])
        XCTAssertNil(unset.propertySurvivorRerunsUnsupportedReason, "none tested again needs nothing")
        XCTAssertNil(try parsed("propertySurvivorReruns: 0").propertySurvivorRerunsUnsupportedReason)
        for wrong in ["propertySurvivorReruns: -1", "propertySurvivorReruns: many", "propertySurvivorRerunLimit: -1"] {
            XCTAssertThrowsError(try parsed(wrong), wrong)
        }

        XCTAssertEqual(
            try parsed("propertySurvivorReruns: 5").propertySurvivorRerunsUnsupportedReason,
            "propertySurvivorReruns needs propertyTestFilter, which selects the property tests to run again"
        )
    }

    // `swift test` and the bundles run directly take `--filter`, xcodebuild `-only-testing:`, each after the rest.
    func test_withPropertyTestFilter_addsTheFilterToEachRunsTestCommand() throws {
        let swift = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["SortProperties", "ParseProperties"]
        )
        let filtered = try XCTUnwrap(swift.withPropertyTestFilter())
        XCTAssertEqual(filtered.testWithoutBuildArguments(with: ""), [
            "test", "--skip-build", "--quiet", "--filter", "SortProperties", "--filter", "ParseProperties",
        ])
        XCTAssertEqual(swift.testWithoutBuildArguments(with: ""), ["test", "--skip-build", "--quiet"])

        let direct = DirectTestRun(
            helper: "/toolchain/swiftpm-testing-helper",
            productsFolder: ".build/debug",
            bundles: ["SortTests"],
            testFiles: [:],
            platformDeveloperFolder: "/Developer",
            arguments: ["--skip-build"]
        )
        let directFiltered = try XCTUnwrap(swift.withDirectTestRun(direct).withPropertyTestFilter()?.directTestRun)
        XCTAssertEqual(
            directFiltered.arguments, ["--skip-build", "--filter", "SortProperties", "--filter", "ParseProperties"]
        )
        let script = directFiltered.script(in: URL(fileURLWithPath: "/project"))
        XCTAssertTrue(script.contains("--filter") && script.contains("SortProperties"), script)

        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["test", "-destination", "platform=macOS"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["SortTests/SortProperties"]
        )
        let xcodeFiltered = try XCTUnwrap(xcode.withPropertyTestFilter())
        XCTAssertEqual(xcodeFiltered.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-only-testing:SortTests/SortProperties",
        ])
    }

    func test_parseKeepAllLogs() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let keeping = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        XCTAssertEqual(try keeping("keepAllLogs: true").keepAllLogs, .enabled)
        XCTAssertTrue(try keeping("keepAllLogs: true").keepsAllLogs)
        XCTAssertFalse(try keeping("keepAllLogs: false").keepsAllLogs)
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))
        XCTAssertEqual(unset.keepAllLogs, .unset)
        XCTAssertFalse(unset.keepsAllLogs)
        // A typo is a configuration error rather than "unset".
        XCTAssertThrowsError(try keeping("keepAllLogs: maybe"))
        // Written back as it was, so a header records it.
        let kept = try keeping("keepAllLogs: true")
        XCTAssertEqual(try MuterConfiguration(from: kept.asData), kept)
    }

    func test_parseKeepSwiftLintPhases() throws {
        let xcodebuild = "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, test]"
        let keeping = { (line: String) in try MuterConfiguration(from: Data("\(xcodebuild)\n\(line)".utf8)) }

        XCTAssertEqual(try keeping("keepSwiftLintPhases: true").keepSwiftLintPhases, .enabled)
        XCTAssertTrue(try keeping("keepSwiftLintPhases: true").keepsSwiftLintPhases)
        XCTAssertFalse(try keeping("keepSwiftLintPhases: false").keepsSwiftLintPhases)
        let unset = try MuterConfiguration(from: Data(xcodebuild.utf8))
        XCTAssertEqual(unset.keepSwiftLintPhases, .unset)
        XCTAssertFalse(unset.keepsSwiftLintPhases)
        // A typo is a configuration error rather than "unset".
        XCTAssertThrowsError(try keeping("keepSwiftLintPhases: sometimes"))
        // Written back as it was, so a header records it.
        let kept = try keeping("keepSwiftLintPhases: true")
        XCTAssertEqual(try MuterConfiguration(from: kept.asData), kept)
    }

    func test_parseKeepLogFolders() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let keeping = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        XCTAssertEqual(try keeping("keepLogFolders: 5").keepLogFolders, 5)
        XCTAssertEqual(try keeping("keepLogFolders: 2").keepLogFolders, 2)
        XCTAssertNil(try MuterConfiguration(from: Data(swiftTest.utf8)).keepLogFolders)
        for value in ["1", "0", "-1", "2.5", "many"] {
            XCTAssertThrowsError(try keeping("keepLogFolders: \(value)"), value)
        }
        // A number below 2 says why: the run before this one is always kept.
        for value in [1, 0, -1] {
            let yaml = Data("\(swiftTest)\nkeepLogFolders: \(value)".utf8)
            XCTAssertThrowsError(try YAMLDecoder().decode(MuterConfiguration.self, from: yaml)) { error in
                XCTAssertTrue("\(error)".contains("keepLogFolders must be a whole number at least 2"), "\(error)")
            }
        }
        // Written back as it was, so a header records it.
        let kept = try keeping("keepLogFolders: 5")
        XCTAssertEqual(try MuterConfiguration(from: kept.asData), kept)
    }

    // A percent, whole or not, from 0 to 100, both included; unset checks no score.
    func test_parseFailUnder() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let failing = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        XCTAssertEqual(try failing("failUnder: 80").failUnder, 80)
        XCTAssertEqual(try failing("failUnder: 72.5").failUnder, 72.5)
        XCTAssertEqual(try failing("failUnder: 0").failUnder, 0)
        XCTAssertEqual(try failing("failUnder: 100").failUnder, 100)
        XCTAssertEqual(try failing("failUnder: 0.000001").failUnder, 0.000001)
        XCTAssertNil(try MuterConfiguration(from: Data(swiftTest.utf8)).failUnder)
        // Written back as it was, in YAML as plain digits, which a reading takes, so `init` and a migration keep it,
        // and in JSON as a number, so a header records it.
        let lines = [("failUnder: 80", "80"), ("failUnder: 72.5", "72.5"), ("failUnder: 0.00001", "0.00001")]
        for (line, written) in lines {
            let configuration = try failing(line)
            let yaml = try configuration.asData
            XCTAssertTrue(String(lossyUTF8: yaml).contains("\nfailUnder: \(written)\n"), line)
            XCTAssertEqual(try MuterConfiguration(from: yaml), configuration, line)
            let json = try JSONEncoder().encode(configuration)
            XCTAssertTrue(String(lossyUTF8: json).contains("\"failUnder\":\(written)"), line)
            XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: json), configuration, line)
        }
        XCTAssertFalse(try String(lossyUTF8: failing("mutationTestWorkers: 2").asData).contains("fail"))
    }

    // A typo is a configuration error rather than "unset", and one out of range says the range.
    func test_failUnderOutOfRange_failsToParse() {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        // Refused as `--fail-under` refuses them, though YAML reads most as numbers: 0x50, 8_0 and 1:20 as 80.
        let refused = ["-1", "100.5", "1000", ".inf", ".nan", "high", "1e2", "0x50", "0o120", "8_0", "1:20", "+80"]
            + ["80.", ".5", "0.0000001", "33.3333333"]
        for value in refused {
            let yaml = Data("\(swiftTest)\nfailUnder: \(value)".utf8)
            XCTAssertThrowsError(try YAMLDecoder().decode(MuterConfiguration.self, from: yaml), value) { error in
                XCTAssertTrue(
                    "\(error)".contains(
                        "failUnder must be a number from 0 to 100, with at most 6 decimals, such as 80 or 72.5, not "
                            + value
                    ),
                    "\(error)"
                )
            }
            XCTAssertNil(ScoreGate.percent(value), value)
        }
        XCTAssertThrowsError(try MuterConfiguration(from: Data("\(swiftTest)\nfailUnder: [80]".utf8)))
        // A JSON configuration's number is checked in its shortest decimal form.
        let numbers = [("1e-7", "0.0000001"), ("33.3333333", "33.3333333"), ("101", "101"), ("-0.5", "-0.5")]
            + [("1e-16", "1e-16")]
        for (number, shown) in numbers {
            let json = Data(#"{"executable": "/usr/bin/swift", "arguments": [], "failUnder": \#(number)}"#.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(MuterConfiguration.self, from: json), number) { error in
                XCTAssertTrue("\(error)".hasSuffix("decimals, such as 80 or 72.5, not \(shown)"), "\(error)")
            }
        }
        let json = Data(#"{"executable": "/usr/bin/swift", "arguments": [], "failUnder": 1e2}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: json).failUnder, 100)
    }

    func test_suspectTestThresholdsOutOfRange_failToParse() {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        for line in [
            "suspectTestFilePercent: 0",
            "suspectTestFilePercent: 101",
            "suspectTestFilePercent: 12.5",
            "suspectTestFilePercent: many",
            "suspectTestMinimumFiles: 0",
            "suspectTestMinimumFiles: -3",
        ] {
            XCTAssertThrowsError(try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)), line)
        }
        XCTAssertNoThrow(try MuterConfiguration(from: Data("\(swiftTest)\nsuspectTestFilePercent: 1".utf8)))
        XCTAssertNoThrow(try MuterConfiguration(from: Data("\(swiftTest)\nsuspectTestMinimumFiles: 1".utf8)))
    }

    func test_parseOneWorkerSimulator() throws {
        let xcodebuild = "executable: /usr/bin/xcodebuild\narguments: [test]"
        let always = try MuterConfiguration(from: Data("\(xcodebuild)\noneWorkerSimulator: true".utf8))
        let never = try MuterConfiguration(from: Data("\(xcodebuild)\noneWorkerSimulator: false".utf8))
        let automatic = try MuterConfiguration(from: Data(xcodebuild.utf8))

        XCTAssertEqual(always.oneWorkerSimulator, .enabled)
        XCTAssertEqual(never.oneWorkerSimulator, .disabled)
        XCTAssertEqual(automatic.oneWorkerSimulator, .unset)
        XCTAssertTrue(try String(lossyUTF8: always.asData).contains("oneWorkerSimulator: true"))
        XCTAssertFalse(try String(lossyUTF8: automatic.asData).contains("oneWorkerSimulator"))
    }

    func test_oneWorkerSimulatorThatIsNotABoolean_failsToParse() {
        let yaml = "executable: /usr/bin/xcodebuild\narguments: [test]\noneWorkerSimulator: auto"

        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)))
    }
}
