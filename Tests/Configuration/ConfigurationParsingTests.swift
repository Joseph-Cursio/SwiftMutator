@testable import muterCore
import XCTest

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

    func test_parseStopAtFirstFailure() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let switchedOn = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: true".utf8))
        let switchedOff = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: false".utf8))
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertTrue(try XCTUnwrap(switchedOn.stopAtFirstFailure))
        XCTAssertFalse(try XCTUnwrap(switchedOff.stopAtFirstFailure))
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
}
