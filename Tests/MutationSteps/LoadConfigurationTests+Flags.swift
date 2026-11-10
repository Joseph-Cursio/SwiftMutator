@testable import muterCore
import XCTest

extension LoadConfigurationTests {
    // After the file's entries, so the header records both.
    func test_excludeFlag_addsToTheKey() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nexclude: [/Gen/]\n".utf8
        )
        state.runOptions = .make(exclude: ["!/Stubs/"])

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.excludeFileList, ["/Gen/", "!/Stubs/"])
    }

    // YAML reads an unquoted `!` entry as a tag on an empty value, which would keep nothing.
    func test_anEmptyExcludeEntry_refusesTheRun_asAnUnquotedBangGivesOne() async throws {
        for yaml in ["exclude:\n  - !/Stubs/\n", "exclude: ['']\n"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data("executable: /usr/bin/swift\narguments: [test]\n\(yaml)".utf8)

            try await assertThrowsMuterError(
                await sut.run(with: state),
                .configurationParsingError(
                    reason: "An `exclude` entry is empty. One that starts with ! must be quoted, as - \"!/Stubs/\"."
                )
            )
        }
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nexclude:\n  - \"!/Stubs/\"\n".utf8
        )
        let result = try await sut.run(with: state)
        guard case let .configurationParsed(quoted)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(quoted.excludeFileList, ["!/Stubs/"])
    }

    // As --workers and --timeout do: the header records it, and a resume only says it changed.
    func test_failUnderFlag_replacesItsKey() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()
        state.runOptions = .make(failUnder: 72.5)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.failUnder, 72.5)
        let fromFile = try XCTUnwrap(MuterConfiguration.fromFixture(
            at: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        ))
        XCTAssertNil(fromFile.failUnder)
        XCTAssertEqual(fromFile.overriding(workers: nil, timeout: nil, failUnder: 72.5), configuration)
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil, failUnder: nil), configuration)
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil, failUnder: 90).failUnder, 90)
    }

    // For this run only, in place of the file's keys, which the header then records and a resume compares.
    func test_workersAndTimeoutFlags_replaceTheirKeys() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()
        state.runOptions = .make(workers: 6, timeout: 45.5)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.mutationTestWorkers, 6)
        XCTAssertEqual(configuration.testSuiteTimeout, 45.5)
        let fromFile = try XCTUnwrap(MuterConfiguration.fromFixture(
            at: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        ))
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil), configuration)
        XCTAssertEqual(fromFile.overriding(workers: 6, timeout: 45.5), configuration)
        XCTAssertNotEqual(fromFile, configuration)
    }

    func test_buildTimeoutFlag_replacesItsKey() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nbuildTimeout: 600\n".utf8
        )
        state.runOptions = .make(buildTimeout: 1_200)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.buildTimeout, 1_200)
    }

    // As the flag is refused: 0 would stop every build at once.
    func test_aBuildTimeoutNotAboveZero_orPastADay_isRefused() async throws {
        for value in ["0", "-5", "86401", ".inf", ".nan"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nbuildTimeout: \(value)\n".utf8
            )

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(
                    reason.hasPrefix("buildTimeout must be a number of seconds above 0, and at most a day (86400)"),
                    "\(value): \(reason)"
                )
            }
        }
    }

    // The flag takes its place, so the run never uses it.
    func test_aBuildTimeoutOutOfRange_isLetThrough_whenTheFlagReplacesIt() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("executable: /usr/bin/swift\narguments: [test]\nbuildTimeout: 0\n".utf8)
        state.runOptions = .make(buildTimeout: 600)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.buildTimeout, 600)
    }

    // In its place, as --property-tests is: the run saves only the reports the command line asks for. The key's paths
    // stay as written, which the header records.
    func test_reportFlag_replacesItsKey() async throws {
        let key = "executable: /usr/bin/swift\narguments: [test]\nreports: [markdown:summary.md]\n"
        let flag = [ReportRequest(format: .html, path: "/out/report.html")]
        for (options, expected) in [
            (Run.Options.make(reports: flag), flag),
            (.make(), [ReportRequest(format: .markdown, path: "summary.md")]),
        ] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(key.utf8)
            state.runOptions = options

            let result = try await sut.run(with: state)

            guard case let .configurationParsed(configuration)? = result.last else {
                XCTFail("\(result)")
                return
            }
            XCTAssertEqual(configuration.reports, expected)
        }
    }
}
