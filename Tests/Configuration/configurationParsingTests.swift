@testable import muterCore
import XCTest
import Yams

final class ConfigurationParsingTests: MuterTestCase {
    func test_parse() {
        let configuration = MuterConfiguration.fromFixture(at: "\(fixturesDirectory)/muter.conf.withoutExcludeList.yml")

        XCTAssertEqual(configuration?.excludeFileList, [])
        XCTAssertEqual(configuration?.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertEqual(configuration?.testCommandArguments, [
            "-project",
            "ExampleApp.xcodeproj",
            "-scheme",
            "ExampleApp",
            "-sdk",
            "iphonesimulator",
            "-destination",
            "platform=iOS Simulator,name=iPhone SE (3rd generation)",
            "test",
        ])
    }

    func test_parseExcludeList() {
        let configuration = MuterConfiguration.fromFixture(at: "\(fixturesDirectory)/muter.conf.withExcludeList.yml")

        XCTAssertEqual(configuration?.excludeFileList, ["ExampleApp"])
    }

    func test_buildSystem_defaultsToExecutableBasename() throws {
        let yaml = """
        executable: /usr/bin/xcodebuild
        arguments: [test]
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertNil(configuration.explicitBuildSystem)
        XCTAssertEqual(configuration.buildSystem, .xcodebuild)
    }

    func test_explicitBuildSystem_overridesWrapperExecutableName() throws {
        // A wrapper executable whose filename isn't `xcodebuild` would otherwise resolve to `.unknown`;
        // the explicit `buildSystem:` key forces the correct build system.
        let yaml = """
        executable: ./.muter-bin/wrapper.sh
        arguments: [test]
        buildSystem: xcodebuild
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertEqual(configuration.explicitBuildSystem, .xcodebuild)
        XCTAssertEqual(configuration.buildSystem, .xcodebuild)
    }

    func test_parseMutationTestWorkers() throws {
        let yaml = """
        executable: /usr/bin/swift
        arguments: [test]
        mutationTestWorkers: 4
        mutationTestTimeout: 30
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertEqual(configuration.mutationTestWorkers, 4)
        XCTAssertEqual(configuration.workerCount, 4)
        XCTAssertEqual(configuration.testSuiteTimeout, 30)
    }

    // In seconds, written as an Int or a Double, like mutationTestTimeout. Unset, nothing has a limit.
    func test_parseBuildTimeout() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let whole = try MuterConfiguration(from: Data("\(swiftTest)\nbuildTimeout: 900".utf8))
        let fraction = try MuterConfiguration(from: Data("\(swiftTest)\nbuildTimeout: 1.5".utf8))
        let json = try MuterConfiguration(
            from: Data(#"{"executable": "/usr/bin/swift", "arguments": ["test"], "buildTimeout": 600}"#.utf8)
        )
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertEqual(whole.buildTimeout, 900)
        XCTAssertEqual(fraction.buildTimeout, 1.5)
        XCTAssertEqual(json.buildTimeout, 600)
        XCTAssertNil(unset.buildTimeout)
        XCTAssertEqual(try MuterConfiguration(from: whole.asData), whole)
    }

    // On one processor, as every test's world has it, unless it says otherwise.
    func test_workerCount_isOneWithoutTheKey_orWithoutASimulatorForXcodebuild() throws {
        let swift = try MuterConfiguration(from: Data("executable: /usr/bin/swift\narguments: [test]".utf8))
        let xcode = try MuterConfiguration(
            from: Data("executable: /usr/bin/xcodebuild\narguments: [test]\nmutationTestWorkers: 4".utf8)
        )
        let zero = MuterConfiguration(executable: "/usr/bin/swift", mutationTestWorkers: 0)

        XCTAssertEqual(swift.workerCount, 1)
        XCTAssertEqual(xcode.workerCount, 1)
        XCTAssertEqual(zero.workerCount, 1)
    }

    // Half the processors, as each worker's tests already run in parallel, and at most 4.
    func test_theDefaultWorkerCount_forSwiftPM_goesByTheProcessors() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let counts = [1: 1, 2: 1, 3: 1, 4: 2, 6: 3, 8: 4, 18: 4, 64: 4]

        for (processors, count) in counts {
            current.processorCount = processors
            XCTAssertEqual(swift.defaultWorkerCount, count, "\(processors)")
            XCTAssertEqual(swift.workerCount, count, "\(processors)")
        }
    }

    func test_theDefaultWorkerCount_isOneForEveryOtherBuildSystem() {
        current.processorCount = 18
        let others = [
            MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"]),
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild", arguments: ["-destination", "platform=macOS", "test"]
            ),
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
            ),
        ]

        for other in others {
            XCTAssertEqual(other.defaultWorkerCount, 1, other.testCommandExecutable)
            XCTAssertEqual(other.workerCount(testing: 500), 1, other.testCommandExecutable)
        }
    }

    // A clone costs about a baseline build, so the default adds a worker only for enough mutants to pay it back.
    func test_workerCountTesting_goesByTheMutants_unlessTheCountIsSet() {
        current.processorCount = 18
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let asked = swift.overriding(workers: 8, timeout: nil)

        let byDefault = [0: 0, 1: 1, 49: 1, 50: 2, 99: 2, 100: 3, 150: 4, 5_000: 4]
        for (mutants, count) in byDefault {
            XCTAssertEqual(swift.workerCount(testing: mutants), count, "\(mutants)")
        }
        let whenSet = [0: 0, 1: 1, 3: 3, 49: 8, 5_000: 8]
        for (mutants, count) in whenSet {
            XCTAssertEqual(asked.workerCount(testing: mutants), count, "\(mutants)")
        }
    }

    // Workers that share a build need no clone, so only the mutants and the count limit them.
    func test_workerCountTesting_sharingABuild_needsNoMutantsToPayItBack() {
        current.processorCount = 18
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])

        let sharing = [0: 0, 1: 1, 3: 3, 4: 4, 49: 4, 5_000: 4]
        for (mutants, count) in sharing {
            XCTAssertEqual(swift.workerCount(testing: mutants, sharingBuild: true), count, "\(mutants)")
        }
        XCTAssertEqual(swift.overriding(workers: 2, timeout: nil).workerCount(testing: 49, sharingBuild: true), 2)
    }

    // Each worker gets a simulator of its own, like the one the first `-destination` names; one named by its id alone
    // is looked up when the run starts.
    func test_workerCount_forXcodebuild_isTheKeysOnASimulator() {
        for destination in [
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=tvOS Simulator,name=Apple TV",
            "id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7",
        ] {
            let configuration = xcodebuild(testingOn: destination, workers: 4)

            XCTAssertEqual(configuration.workerCount, 4, destination)
            XCTAssertNil(configuration.parallelWorkersUnsupportedReason, destination)
        }
    }

    func test_workerCount_forXcodebuild_isOneOffASimulator() {
        let mac = "a Mac app's test runs share its UserDefaults, saved state and container, so workers would see each "
            + "other's"
        let reasons = [
            "platform=macOS": mac,
            "platform=macOS,arch=x86_64": mac,
            "platform=macOS,variant=Mac Catalyst": mac,
            "platform=iOS,id=00008110-000A1C2E3F45801E": "an xcodebuild project tests more than one at once only on "
                + "a simulator, which `-destination platform=iOS,id=00008110-000A1C2E3F45801E` doesn't name",
            "generic/platform=iOS Simulator": "an xcodebuild project tests more than one at once only on a simulator, "
                + "which `-destination generic/platform=iOS Simulator` doesn't name",
        ]

        for (destination, reason) in reasons {
            let configuration = xcodebuild(testingOn: destination, workers: 4)

            XCTAssertEqual(configuration.workerCount, 1, destination)
            XCTAssertEqual(configuration.parallelWorkersUnsupportedReason, reason, destination)
        }
        XCTAssertEqual(
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]).parallelWorkersUnsupportedReason,
            "an xcodebuild project tests more than one at once only on a simulator, and the test command gives no "
                + "`-destination`"
        )
    }

    func test_workerCount_forAnotherBuildSystem_isOne() {
        let other = MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"], mutationTestWorkers: 4)

        XCTAssertEqual(other.workerCount, 1)
        XCTAssertEqual(
            other.parallelWorkersUnsupportedReason,
            "only SwiftPM projects, and xcodebuild projects that test on a simulator, test more than one at once"
        )
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertNil(swift.parallelWorkersUnsupportedReason)
    }

    // A `-destination` with no value after it is no destination, rather than a crash.
    func test_firstDestination_isTheFirstsValue() {
        XCTAssertEqual(
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-destination", "platform=macOS", "-destination", "id=X", "test"]
            ).firstDestination,
            "platform=macOS"
        )
        XCTAssertNil(MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test", "-destination"])
            .firstDestination)
    }

    func test_withDefaultTestSuiteTimeout_fillsInOnlyAMissingTimeout() {
        XCTAssertEqual(MuterConfiguration().withDefaultTestSuiteTimeout(12).testSuiteTimeout, 12)
        XCTAssertEqual(
            MuterConfiguration(testSuiteTimeOut: 5, mutationTestWorkers: 3).withDefaultTestSuiteTimeout(12),
            MuterConfiguration(testSuiteTimeOut: 5, mutationTestWorkers: 3)
        )
    }

    func test_parseStopAtFirstFailure() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let switchedOn = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: true".utf8))
        let switchedOff = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: false".utf8))
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertEqual(switchedOn.stopAtFirstFailure, true)
        XCTAssertEqual(switchedOff.stopAtFirstFailure, false)
        XCTAssertNil(unset.stopAtFirstFailure)
    }

    func test_stopAtFirstFailureThatIsNotABoolean_failsToParse() {
        // An error, as for mutationTestWorkers, rather than read as unset: a typo would otherwise leave
        // every run going to its end without a word.
        let yaml = "executable: /usr/bin/swift\narguments: [test]\nstopAtFirstFailure: sometimes"

        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)))
    }

    func test_parseTheSuspectTestThresholds() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let set = try MuterConfiguration(
            from: Data("\(swiftTest)\nsuspectTestFilePercent: 25\nsuspectTestMinimumFiles: 4".utf8)
        )
        let percentOnly = try MuterConfiguration(from: Data("\(swiftTest)\nsuspectTestFilePercent: 100".utf8))
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertEqual(set.suspectTestThresholds, SuspectTestThresholds(filePercent: 25, minimumFiles: 4))
        XCTAssertEqual(percentOnly.suspectTestThresholds, SuspectTestThresholds(filePercent: 100, minimumFiles: 10))
        XCTAssertNil(unset.suspectTestFilePercent)
        XCTAssertNil(unset.suspectTestMinimumFiles)
        XCTAssertEqual(unset.suspectTestThresholds, .standard)
        // Written back as they were, so a header records them.
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set)
    }

    func test_parseSuspectKillReruns() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let limit = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        XCTAssertEqual(try limit("suspectKillReruns: 250").killsToTestAgainAlone, 250)
        XCTAssertEqual(try limit("suspectKillReruns: 0").killsToTestAgainAlone, 0)
        XCTAssertEqual(try MuterConfiguration(from: Data(swiftTest.utf8)).killsToTestAgainAlone, 100)
        for line in ["suspectKillReruns: -1", "suspectKillReruns: many", "suspectKillReruns: 2.5"] {
            XCTAssertThrowsError(try limit(line), line)
        }
    }

    func test_parseControlRunEvery() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let every = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        XCTAssertEqual(try every("controlRunEvery: 250").mutantsPerControlRun, 250)
        XCTAssertEqual(try every("controlRunEvery: 0").mutantsPerControlRun, 0)
        XCTAssertEqual(try MuterConfiguration(from: Data(swiftTest.utf8)).mutantsPerControlRun, 100)
        for line in ["controlRunEvery: -1", "controlRunEvery: often", "controlRunEvery: 2.5"] {
            XCTAssertThrowsError(try every(line), line)
        }
    }

    func test_parsePropertyTests() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let globs = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        let set = try globs("propertyTests: ['*Properties*', SortSpec.swift]")
        XCTAssertEqual(set.propertyTests, ["*Properties*", "SortSpec.swift"])
        XCTAssertNil(try MuterConfiguration(from: Data(swiftTest.utf8)).propertyTests)
        // An empty glob matches no test, and a single string isn't a list: each is a configuration error.
        for line in ["propertyTests: ['']", "propertyTests: '*Properties*'", "propertyTests: 3"] {
            XCTAssertThrowsError(try globs(line), line)
        }
        // Written back as they were, so a header records them, and `--property-tests` replaces them.
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set)
        let overridden = set.overriding(workers: nil, timeout: nil, propertyTests: ["*Spec*"])
        XCTAssertEqual(overridden.propertyTests, ["*Spec*"])
        XCTAssertEqual(set.overriding(workers: nil, timeout: nil).propertyTests, set.propertyTests)
    }

    func test_parseReports() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let reports = { (line: String) in try MuterConfiguration(from: Data("\(swiftTest)\n\(line)".utf8)) }

        // Split at the first colon only, as a path may hold one, and kept as written: a run resolves it when it saves.
        let set = try reports("reports: [markdown:summary.md, 'html:out/a:b.html', json:/tmp/report.json]")
        XCTAssertEqual(set.reports, [
            ReportRequest(format: .markdown, path: "summary.md"),
            ReportRequest(format: .html, path: "out/a:b.html"),
            ReportRequest(format: .json, path: "/tmp/report.json"),
        ])
        XCTAssertNil(try MuterConfiguration(from: Data(swiftTest.utf8)).reports)
        XCTAssertEqual(
            set.reportRequests(in: URL(fileURLWithPath: "/project")).map(\.path),
            ["/project/summary.md", "/project/out/a:b.html", "/tmp/report.json"]
        )
        let wrong = [
            ("reports: [summary.md]", "reports: name the format and then the path"),
            ("reports: [pdf:summary.pdf]", "start with one of the formats plain, json, html, markdown,"),
            ("reports: ['markdown:']", "reports: give a path after the format"),
            ("reports: [xcode:report.txt]", "reports: save the Xcode format with -f xcode"),
            ("reports: markdown:summary.md", ""),
            ("reports: 3", ""),
        ]
        for (line, reason) in wrong {
            XCTAssertThrowsError(try reports(line), line) { error in
                XCTAssertTrue(reason.isEmpty || "\(error)".contains(reason), "\(error)")
            }
        }
        // Written back as they were, in YAML and in JSON, so a header records them, and `--report` replaces them.
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set)
        XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: JSONEncoder().encode(set)), set)
        let flag = [ReportRequest(format: .plain, path: "/out/report.txt")]
        XCTAssertEqual(set.overriding(workers: nil, timeout: nil, reports: flag).reports, flag)
        XCTAssertEqual(set.overriding(workers: nil, timeout: nil).reports, set.reports)
    }

    // After the file's, so a header records both, and a resume compares them as it does the key.
    func test_excludeFromTheCommandLine_isAddedToTheFiles() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], excludeList: ["/Gen/"]
        )
        let overridden = configuration.overriding(workers: nil, timeout: nil, exclude: ["!/Stubs/"])
        XCTAssertEqual(overridden.excludeFileList, ["/Gen/", "!/Stubs/"])
        XCTAssertEqual(try MuterConfiguration(from: overridden.asData).excludeFileList, ["/Gen/", "!/Stubs/"])
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil), configuration)
    }

    func test_buildTimeoutFromTheCommandLine_replacesTheKey() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 600)
        let overridden = configuration.overriding(workers: nil, timeout: nil, buildTimeout: 1_200)
        XCTAssertEqual(overridden.buildTimeout, 1_200)
        XCTAssertEqual(try MuterConfiguration(from: overridden.asData).buildTimeout, 1_200)
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil).buildTimeout, 600)
    }

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

        XCTAssertEqual(try keeping("keepAllLogs: true").keepAllLogs, true)
        XCTAssertTrue(try keeping("keepAllLogs: true").keepsAllLogs)
        XCTAssertFalse(try keeping("keepAllLogs: false").keepsAllLogs)
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))
        XCTAssertNil(unset.keepAllLogs)
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

        XCTAssertEqual(try keeping("keepSwiftLintPhases: true").keepSwiftLintPhases, true)
        XCTAssertTrue(try keeping("keepSwiftLintPhases: true").keepsSwiftLintPhases)
        XCTAssertFalse(try keeping("keepSwiftLintPhases: false").keepsSwiftLintPhases)
        let unset = try MuterConfiguration(from: Data(xcodebuild.utf8))
        XCTAssertNil(unset.keepSwiftLintPhases)
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
            XCTAssertTrue(String(decoding: yaml, as: UTF8.self).contains("\nfailUnder: \(written)\n"), line)
            XCTAssertEqual(try MuterConfiguration(from: yaml), configuration, line)
            let json = try JSONEncoder().encode(configuration)
            XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"failUnder\":\(written)"), line)
            XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: json), configuration, line)
        }
        XCTAssertFalse(try String(decoding: failing("mutationTestWorkers: 2").asData, as: UTF8.self).contains("fail"))
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

        XCTAssertEqual(always.oneWorkerSimulator, true)
        XCTAssertEqual(never.oneWorkerSimulator, false)
        XCTAssertNil(automatic.oneWorkerSimulator)
        XCTAssertTrue(try String(decoding: always.asData, as: UTF8.self).contains("oneWorkerSimulator: true"))
        XCTAssertFalse(try String(decoding: automatic.asData, as: UTF8.self).contains("oneWorkerSimulator"))
    }

    func test_oneWorkerSimulatorThatIsNotABoolean_failsToParse() {
        let yaml = "executable: /usr/bin/xcodebuild\narguments: [test]\noneWorkerSimulator: auto"

        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)))
    }

    func test_parallelTestingArguments() {
        let cases: [(arguments: [String], expected: MuterConfiguration.ParallelTestingArguments)] = [
            (["test"], .unset),
            (["-parallel-testing-enabled", "YES", "test"], .enabled),
            (["-parallel-testing-enabled", "yes", "test"], .enabled),
            (["-parallel-testing-enabled", "NO", "test"], .disabled),
            (["-parallel-testing-worker-count", "3", "-parallel-testing-enabled", "no"], .disabled),
            // Options that only tune it leave it to the scheme or the test plan.
            (["-parallel-testing-worker-count", "3", "test"], .unset),
            (["-maximum-parallel-testing-workers", "2", "test"], .unset),
            (["-parallelize-tests-among-destinations", "test"], .unset),
            (["-maximum-parallel-testing-workers", "2", "-parallel-testing-enabled", "YES"], .enabled),
            (["test", "-parallel-testing-enabled"], .unset),
        ]
        for (arguments, expected) in cases {
            let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)
            XCTAssertEqual(configuration.parallelTestingArguments, expected, "\(arguments)")
        }
    }

    func test_stopsAtFirstFailure_forSwiftPMUnlessSwitchedOff() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: true)
        XCTAssertTrue(swift.stopsAtFirstFailure)
        XCTAssertNil(swift.stopAtFirstFailureUnsupportedReason)

        // On by default: an unset key stops, and only an explicit false doesn't.
        XCTAssertTrue(MuterConfiguration(executable: "/usr/bin/swift").stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: false).stopsAtFirstFailure)

        // xcodebuild runs the tests in a process SwiftMutator can't stop, whether the key is set or not.
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", stopAtFirstFailure: true)
        XCTAssertFalse(xcode.stopsAtFirstFailure)
        XCTAssertNotNil(xcode.stopAtFirstFailureUnsupportedReason)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/xcodebuild").stopsAtFirstFailure)

        // A wrapper script counts only when the configuration says it runs `swift test`.
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh", stopAtFirstFailure: true).stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh").stopsAtFirstFailure)
        XCTAssertTrue(
            MuterConfiguration(executable: "/bin/sh", buildSystem: .swift, stopAtFirstFailure: true).stopsAtFirstFailure
        )
        XCTAssertTrue(MuterConfiguration(executable: "/bin/sh", buildSystem: .swift).stopsAtFirstFailure)
    }

    func test_stopsAtFirstFailure_isOffWhenFailingTestsAreRetried() {
        for arguments in [["test", "--repeat-until", "pass"], ["test", "--repeat-until=pass"]] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: arguments,
                stopAtFirstFailure: true
            )

            XCTAssertFalse(configuration.stopsAtFirstFailure, "\(arguments)")
            XCTAssertNotNil(configuration.stopAtFirstFailureUnsupportedReason, "\(arguments)")
        }
    }

    // A passing baseline printed a line shaped like a failed test, so such a line can't stop a run.
    func test_stopsAtFirstFailure_isOffOnceFailedTestLinesAreUnreliable() {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: true)

        XCTAssertTrue(configuration.failedTestLinesAreReliable)
        XCTAssertTrue(configuration.stopsAtFirstFailure)
        XCTAssertFalse(configuration.withUnreliableFailedTestLines().stopsAtFirstFailure)
    }

    // Swift Testing then prints no line for each test that starts or passes; a verbosity the arguments set is kept.
    func test_testWithoutBuildArguments_forSwiftPM_skipTheBuild_quietly_unlessTheArgumentsSetAVerbosity() {
        let quiet = { (arguments: [String]) in
            MuterConfiguration(executable: "/usr/bin/swift", arguments: arguments).testWithoutBuildArguments(with: "")
        }

        XCTAssertEqual(quiet(["test", "--filter", "Core"]), ["test", "--filter", "Core", "--skip-build", "--quiet"])
        for verbosity in ["-q", "--quiet", "-v", "--verbose", "--very-verbose", "--vv"] {
            XCTAssertEqual(quiet(["test", verbosity]), ["test", verbosity, "--skip-build"], verbosity)
        }
        // xcodebuild has its own arguments for a run without building.
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test", "-destination", "platform=macOS"]
        )
        XCTAssertFalse(xcode.testWithoutBuildArguments(with: "run.xctestrun").contains("--quiet"))
    }

    // Each run of a mutant keeps its derived data beside the copy, not in ~/Library/Developer/Xcode/DerivedData. The
    // `.xctestrun` takes the place of `-scheme`, and the run's own action of `test`.
    func test_testWithoutBuildArguments_forXcodebuild_addTheWorkersDerivedData() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
        ])
        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
        ])
    }

    // Only when the xcodebuild in use takes it (see BuildForTesting).
    func test_testWithoutBuildArguments_forXcodebuild_turnOffTestDiagnosticsWhenTheWorkerSays() {
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["-destination", "platform=macOS"])
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
            "-collect-test-diagnostics", "never",
        ])
    }

    func test_testWithoutBuildArguments_forXcodebuild_useTheWorkersDestinationAndTestRunFile() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "-only-testing", "AppTests", "test"]
        )
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker2.xctestrun",
            derivedData: "/path/App_mutated_worker2.DerivedData",
            destination: "platform=iOS Simulator,id=8C5A2F0E",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,id=8C5A2F0E",
            "-xctestrun", "muter-worker2.xctestrun",
            "-only-testing", "AppTests",
            "-derivedDataPath", "/path/App_mutated_worker2.DerivedData",
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO",
        ])
    }

    // What says which tests run and how holds for every mutant, as it did for the baseline (#123). What the
    // `.xctestrun` takes the place of, every action and `-destination`, and what would break or slow each run, are left
    // out, each with its value.
    func test_testWithoutBuildArguments_forXcodebuild_keepTheTestCommandsOwnArguments() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-workspace", "App.xcworkspace", "-project", "App.xcodeproj", "-scheme", "App", "-testPlan", "Unit",
                "-destination", "platform=macOS", "-destination", "platform=macOS,variant=Mac Catalyst",
                "-only-testing:AppTests", "-skip-testing:AppTests/SlowTests", "-only-test-configuration", "English",
                "-test-iterations", "3", "-retry-tests-on-failure", "-test-timeouts-enabled", "YES",
                "-skip-test-configuration", "German", "-run-tests-until-failure", "-testLanguage", "en",
                "-testRegion", "US", "-destination-timeout", "30", "-default-test-execution-time-allowance", "60",
                "-maximum-test-execution-time-allowance", "120",
                "-parallel-testing-worker-count", "2", "-configuration", "Debug", "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
                "-quiet", "-resultStreamPath", "stream.json", "-enableCodeCoverage", "NO", "-derivedDataPath", "DD",
                "-collect-test-diagnostics", "on-failure", "clean", "build", "test",
            ]
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-only-testing:AppTests", "-skip-testing:AppTests/SlowTests", "-only-test-configuration", "English",
            "-test-iterations", "3", "-retry-tests-on-failure", "-test-timeouts-enabled", "YES",
            "-skip-test-configuration", "German", "-run-tests-until-failure", "-testLanguage", "en",
            "-testRegion", "US", "-destination-timeout", "30", "-default-test-execution-time-allowance", "60",
            "-maximum-test-execution-time-allowance", "120",
            "-parallel-testing-worker-count", "2", "-configuration", "Debug", "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
            "-derivedDataPath", "DD",
            "-collect-test-diagnostics", "on-failure",
        ])
    }

    // xcodebuild takes `-derivedDataPath` and `-parallel-testing-enabled` once, so the worker's own replace the test
    // command's, as do its test diagnostics and, on a simulator of its own, everything that tunes parallel testing.
    func test_testWithoutBuildArguments_forXcodebuild_leaveOutWhatTheWorkerSetsItself() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-destination", "platform=iOS Simulator,name=iPhone 17", "-derivedDataPath", "DD",
                "-collect-test-diagnostics", "on-failure", "-parallel-testing-enabled", "YES",
                "-maximum-parallel-testing-workers", "4", "-parallel-testing-worker-count", "2",
                "-parallelize-tests-among-destinations", "-skip-testing:AppUITests", "test",
            ]
        )
        let onTheDestination = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )
        let onASimulator = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/path/App_mutated_worker1.DerivedData",
            destination: "platform=iOS Simulator,id=8C5A2F0E",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(onTheDestination).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
            "-collect-test-diagnostics", "on-failure", "-parallel-testing-enabled", "YES",
            "-maximum-parallel-testing-workers", "4", "-parallel-testing-worker-count", "2",
            "-parallelize-tests-among-destinations", "-skip-testing:AppUITests",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
        ])
        XCTAssertEqual(xcode.forXcodeWorker(onASimulator).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,id=8C5A2F0E",
            "-xctestrun", "muter-worker1.xctestrun",
            "-skip-testing:AppUITests",
            "-derivedDataPath", "/path/App_mutated_worker1.DerivedData",
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO",
        ])
    }

    // xcodebuild runs every test any `-only-testing` names, so the test command's would undo the filter, which selects
    // tests of its own; `-skip-testing` still leaves out what it names.
    func test_testWithoutBuildArguments_forXcodebuild_withATestFilter_leaveOutOnlyTheTestCommandsOnlyTesting() throws {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-destination", "platform=macOS", "-only-testing:SortTests", "-only-testing", "ParseTests",
                "-skip-testing:SortTests/SlowProperties", "test",
            ],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["SortTests/SortProperties"]
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-only-testing:SortTests", "-only-testing", "ParseTests", "-skip-testing:SortTests/SlowProperties",
        ])
        let filtered = try XCTUnwrap(xcode.withPropertyTestFilter())
        XCTAssertEqual(filtered.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-skip-testing:SortTests/SlowProperties",
            "-only-testing:SortTests/SortProperties",
        ])
    }

    // A wrapper script is given the arguments as xcodebuild would be, its own flags among them.
    func test_testWithoutBuildArguments_forAWrapperScript_keepItsOwnFlags() {
        let wrapper = MuterConfiguration(
            executable: "/project/ci/run-tests.sh",
            arguments: [
                "--simulator-env", "SIMCTL_CHILD_LOG=1", "-destination", "platform=macOS", "-scheme", "App", "test",
            ],
            buildSystem: .xcodebuild
        )

        XCTAssertEqual(wrapper.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "--simulator-env", "SIMCTL_CHILD_LOG=1",
        ])
    }

    // Beside the copy, so neither its fingerprint nor the build its runs test from sees it.
    // Its name ends in `.noindex`, so Spotlight skips it, whether the copy's name does or, as a test plan's copy made
    // by an older SwiftMutator, doesn't.
    func test_aWorkersDerivedData_isBesideTheMutatedProject() {
        for mutated in ["/path/App_mutated.noindex", "/path/App_mutated"].map(URL.init(fileURLWithPath:)) {
            XCTAssertEqual(
                MuterConfiguration.XcodeWorker.derivedData(ofWorker: 0, in: mutated),
                "/path/App_mutated.DerivedData.noindex"
            )
            XCTAssertEqual(
                MuterConfiguration.XcodeWorker.derivedData(ofWorker: 3, in: mutated),
                "/path/App_mutated_worker3.DerivedData.noindex"
            )
        }
    }

    // Not a configuration key: neither the configuration file nor a results file's header holds it.
    func test_xcodeWorker_isNeverEncoded() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let withWorker = configuration.forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        ))

        XCTAssertEqual(try withWorker.asData, try configuration.asData)
        XCTAssertEqual(try MuterConfiguration(from: withWorker.asData), configuration)
    }

    func test_asData_writesStopAtFirstFailureOnlyWhenSet() throws {
        // Left out while unset, so `init` and the JSON-to-YAML migration write the same files as before.
        let unset = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertFalse(try String(decoding: unset.asData, as: UTF8.self).contains("stopAtFirstFailure"))

        for value in [true, false] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: ["test"],
                stopAtFirstFailure: value
            )

            XCTAssertTrue(
                try String(decoding: configuration.asData, as: UTF8.self).contains("stopAtFirstFailure: \(value)")
            )
            XCTAssertEqual(try MuterConfiguration(from: configuration.asData), configuration)
        }
    }

    func test_configurationWithEveryFieldSet_leavesNoFieldAtItsDefault() {
        // A field added to MuterConfiguration fails this until the helper in Fixtures.swift sets it, which makes
        // the copy tests that follow cover the new field too.
        let fields = Mirror(reflecting: configurationWithEveryFieldSet()).children
        let defaults = Mirror(reflecting: MuterConfiguration()).children
        for (field, defaultField) in zip(fields, defaults) {
            XCTAssertNotEqual(
                "\(field.value)",
                "\(defaultField.value)",
                "\(field.label ?? "a field") is at its default"
            )
        }
    }

    func test_operatorKeys_areRead_andAnythingElseIsAConfigurationError() throws {
        let start = "executable: /usr/bin/swift\narguments: [test]\n"
        let read = { (line: String) in try MuterConfiguration(from: Data((start + line).utf8)) }

        let set = try read("operators: [SwapTernary, RelationalBoundary]\nskipOperators: [SwapTernary]")
        XCTAssertEqual(set.operators, [.swapTernary, .relationalBoundary])
        XCTAssertEqual(set.skipOperators, [.swapTernary])
        XCTAssertEqual(try read("skipOperators: []").skipOperators, [])
        let neither = try read("")
        XCTAssertNil(neither.operators)
        XCTAssertNil(neither.skipOperators)

        let wrong = [
            ("operators: [SwapTernery]", "SwapTernery isn't an operator"),
            ("skipOperators: [SwapTernery]", "SwapTernery isn't an operator"),
            ("operators: []", "must name at least one operator"),
            ("operators:", "must name at least one operator"),
            ("operators: SwapTernary", ""),
            ("skipOperators: 3", ""),
        ]
        for (line, reason) in wrong {
            XCTAssertThrowsError(try read(line), line) { error in
                XCTAssertTrue(reason.isEmpty || "\(error)".contains(reason), "\(error)")
            }
        }
    }

    func test_everyKey_isWritten_andReadBack() throws {
        // encode(to:) is written by hand, so a key added to CodingKeys but not written there would be lost from every
        // results header and never compared on a resume.
        let configuration = configurationWithEveryFieldSet()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(configuration)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertEqual(Set(written.keys), Set(MuterConfiguration.CodingKeys.allCases.map(\.stringValue)))
        XCTAssertEqual(
            try encoder.encode(JSONDecoder().decode(MuterConfiguration.self, from: json)),
            json
        )
        XCTAssertEqual(
            try encoder.encode(MuterConfiguration(from: configuration.asData)),
            json
        )
    }

    func test_withExecutable_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet().withExecutable("/opt/homebrew/bin/swift"),
            configurationWithEveryFieldSet(executable: "/opt/homebrew/bin/swift")
        )
    }

    func test_withDefaultTestSuiteTimeout_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(timeout: nil).withDefaultTestSuiteTimeout(12),
            configurationWithEveryFieldSet(timeout: 12)
        )
    }

    func test_forXcodeWorker_keepsEveryOtherField() throws {
        let configuration = configurationWithEveryFieldSet()
        let worker = try XCTUnwrap(configuration.xcodeWorker)
        let other = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )

        XCTAssertEqual(configuration.forXcodeWorker(other).xcodeWorker, other)
        XCTAssertEqual(configuration.forXcodeWorker(other).forXcodeWorker(worker), configuration)
    }

    func test_withUnreliableFailedTestLines_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(failedTestLinesAreReliable: true)
                .withUnreliableFailedTestLines(printedIn: [failedTestLookalikeLog]),
            configurationWithEveryFieldSet(failedTestLinesAreReliable: false)
        )
    }

    /// An xcodebuild test command on `destination`, with `workers` workers.
    private func xcodebuild(testingOn destination: String, workers: Int) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: workers
        )
    }
}
