@testable import muterCore
import XCTest
import Yams

final class LoadConfigurationTests: MuterTestCase {
    private lazy var currentDirectory = fixturesDirectory
    private lazy var sut = LoadConfiguration()
    private var state = MutationTestState()

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = fixturesDirectory
    }

    func test_loadLJSONConfigurationFromDisk() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()

        let result = try await sut.run(with: state)

        let expectedUrl = URL(fileURLWithPath: fixturesDirectory)
        let expectedConfiguration = try XCTUnwrap(MuterConfiguration.fromFixture(
            at: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        ))

        XCTAssertEqual(result, [
            .projectDirectoryUrlDiscovered(expectedUrl),
            .configurationParsed(expectedConfiguration),
        ])
    }

    func test_theConfigurationsOperators_areChosen_whichTheStateThenHolds() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("""
        executable: /usr/bin/swift
        arguments: [test]
        operators: [SwapTernary, RemoveSideEffects]
        skipOperators: [RemoveSideEffects]
        """.utf8)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.last, .operatorsChosen([.swapTernary]))
        state.apply(result)
        XCTAssertEqual(state.mutationOperatorList, [.swapTernary])
    }

    func test_leavingEveryOperatorOut_refusesTheRun() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("""
        executable: /usr/bin/swift
        arguments: [test]
        operators: [SwapTernary]
        skipOperators: [SwapTernary]
        """.utf8)

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("Every operator is left out"), "\(error)")
        }
    }

    // Now, so a typo in a label doesn't wait for the end of a long run.
    func test_aBrokenTriageFile_refusesTheRun() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()
        fileManager.fileContentsToReturn = Data("mutants: [".utf8)

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains(TriageFile.fileName), "\(error)")
        }
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

    // As --report's are: each needs a file of its own, resolved against the project's folder, which -o's is beside.
    func test_reportsThatClash_withOutputOrEachOther_areRefused() async throws {
        let clashes = [
            (
                Run.Options.make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/summary.md")),
                "-o \(fixturesDirectory)/summary.md and reports: markdown:\(fixturesDirectory)/summary.md would save "
                    + "to the same file"
            ),
            (
                .make(writeBaseline: "\(fixturesDirectory)/summary.md"),
                "reports: markdown:\(fixturesDirectory)/summary.md and --write-baseline "
                    + "\(fixturesDirectory)/summary.md would save to the same file"
            ),
            (
                .make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/summary.partial.md")),
                "-o \(fixturesDirectory)/summary.partial.md would save where reports: "
                    + "markdown:\(fixturesDirectory)/summary.md's partial report goes when a run stops"
            ),
        ]
        for (options, clash) in clashes {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nreports: [markdown:summary.md]\n".utf8
            )
            state.runOptions = options

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                XCTAssertEqual(
                    error,
                    .configurationParsingError(reason: "\(clash): give each report a path of its own.")
                )
            }
        }
    }

    // Saving would replace it and everything in it, so a run refuses it before it starts, as `report` does.
    func test_aReportPathThatIsAFolder_isRefused() async throws {
        let refusals = [
            (
                Run.Options.make(),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in reports: "
                    + "markdown:\(fixturesDirectory)/Docs."
            ),
            (
                .make(reports: [ReportRequest(format: .html, path: "\(fixturesDirectory)/Docs")]),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in --report "
                    + "html:\(fixturesDirectory)/Docs."
            ),
            (
                .make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/Docs"), reports: []),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in -o "
                    + "\(fixturesDirectory)/Docs."
            ),
            (
                .make(reports: [], writeBaseline: "\(fixturesDirectory)/Docs"),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in --write-baseline "
                    + "\(fixturesDirectory)/Docs."
            ),
        ]
        fileManager.directoriesToReturn = ["\(fixturesDirectory)/Docs"]
        for (options, reason) in refusals {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nreports: [markdown:Docs]\n".utf8
            )
            state.runOptions = options

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                XCTAssertEqual(error, .configurationParsingError(reason: reason))
            }
        }
    }

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

    func test_migrationToYaml() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertTrue(fileManager.methodCalls.contains("removeItem(atPath:)"))
        XCTAssertTrue(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        assertConfigurationsEquals(
            fileManager.contents,
            loadYAMLConfiguration()
        )
    }

    // Not `/muter.conf.json`, at the root of the disk, which real runs read until it was fixed. This spy returns its
    // contents for any path, so only the path shows it.
    func test_migration_readsAndReplacesTheLegacyFile_inTheProject() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()

        _ = try await sut.run(with: state)

        let legacy = "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        XCTAssertEqual(fileManager.contentsAtPath.first, legacy)
        XCTAssertEqual(
            Array(fileManager.createdFiles.keys),
            ["\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"]
        )
        XCTAssertEqual(fileManager.paths.last, legacy)
    }

    func test_migration_inACustomFolder_staysThere() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        state.runOptions = .make(configurationURL: URL(fileURLWithPath: "/some/custom/path"))

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsAtPath.first, "/some/custom/path/muter.conf.json")
        XCTAssertEqual(Array(fileManager.createdFiles.keys), ["/some/custom/path/muter.conf.yml"])
        XCTAssertEqual(fileManager.paths.last, "/some/custom/path/muter.conf.json")
    }

    // Migrating would overwrite the YAML file with the legacy file's older settings.
    func test_aYAMLFile_winsOverALegacyFile_whichStays() async throws {
        fileManager.fileExistsToReturn = [true, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.contentsAtPath.first,
            "\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"
        )
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
        XCTAssertEqual(fileManager.createdFiles, [:])
    }

    func test_aFailedMigration_keepsTheLegacyFile() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        fileManager.createFileToReturn = false

        _ = try await sut.run(with: state)

        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }

    func test_aMissingFileThatConfigurationNames_isNotReplacedByALegacyFile() async throws {
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = loadJSONConfiguration()
        state.runOptions = .make(configurationURL: URL(fileURLWithPath: "/some/custom/other.yml"))

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("/some/custom/other.yml"), "\(error)")
        }
        XCTAssertEqual(fileManager.contentsAtPath, [])
        XCTAssertEqual(fileManager.createdFiles, [:])
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }

    private func assertConfigurationsEquals(
        _ actual: Data?,
        _ expected: Data?
    ) {
        guard let actual,
              let expected
        else {
            XCTFail("Could not assert configurations")
            return
        }

        let actualConfig = try? YAMLDecoder().decode(
            MuterConfiguration.self,
            from: actual
        )
        let expectedConfig = try? YAMLDecoder().decode(
            MuterConfiguration.self,
            from: expected
        )

        XCTAssertEqual(actualConfig, expectedConfig)
    }

    func test_failure() async throws {
        currentDirectory = "/some/projectName"
        fileManager.fileExistsToReturn = [false, false]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .configurationParsingError(reason) = error else {
                XCTFail("Expected configurationParsingError, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_whenUsingXcodeBuildSystem_shouldRequireDestinationInTestArguments() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfigurationWithoutDestination()

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .configurationParsingError(reason) = error else {
                XCTFail("Expected configurationParsingError, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_whenExecutableIsABareCommandName_thenItIsResolvedToItsPathLocation() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = try MuterConfiguration(
            executable: "swift",
            arguments: ["test"]
        ).asData
        process.stdoutToBeReturned = "/usr/bin/swift\n"

        let result = try await sut.run(with: state)

        // A bare command name is only resolvable by searching PATH. Later steps run the test command
        // from Muter's copy of the project, where `Process` would look for a file literally named
        // "swift" — so the configuration has to carry the absolute path from here on.
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/which")
        XCTAssertEqual(process.arguments, ["swift"])
        XCTAssertEqual(
            result.last,
            .configurationParsed(
                MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
            )
        )
    }

    func test_whenExecutableIsABareCommandName_thenMutationTestWorkersIsKept() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = try MuterConfiguration(
            executable: "swift",
            arguments: ["test"],
            mutationTestWorkers: 4
        ).asData
        process.stdoutToBeReturned = "/usr/bin/swift\n"

        let result = try await sut.run(with: state)

        // Resolving the path must change only `executable`. A setting lost on the way falls back to its
        // default without a word: for `mutationTestWorkers`, that means testing one mutant at a time.
        XCTAssertEqual(
            result.last,
            .configurationParsed(
                MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4)
            )
        )
    }

    func test_whenExecutableIsAnAbsolutePath_thenItIsLeftAlone() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = try MuterConfiguration(
            executable: "/opt/homebrew/bin/swift",
            arguments: ["test"]
        ).asData

        let result = try await sut.run(with: state)

        XCTAssertNil(process.executableURL)
        XCTAssertEqual(
            result.last,
            .configurationParsed(
                MuterConfiguration(executable: "/opt/homebrew/bin/swift", arguments: ["test"])
            )
        )
    }

    func test_whenExecutableIsNotOnPath_thenFailWithAnActionableError() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = try MuterConfiguration(
            executable: "swiftly",
            arguments: ["test"]
        ).asData

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            // Reported verbatim: the configuration file itself parsed fine, so calling this a parsing
            // error would point the user at the wrong problem.
            guard case let .literal(reason) = error else {
                XCTFail("Expected literal, got \(error)")
                return
            }

            XCTAssertTrue(
                reason.contains("swiftly"),
                "Expected the error to name the executable it couldn't find, got: \(reason)"
            )
            XCTAssertTrue(reason.contains("PATH"), reason)
        }
    }

    func test_loadingConfigurationFromCustomPath() async throws {
        fileManager.fileContentsToReturn = loadYAMLConfiguration()
        fileManager.fileExistsToReturn = [false, true]

        let configurationURL = URL(fileURLWithPath: "/some/custom/path")
        state.runOptions = .make(configurationURL: configurationURL)

        _ = try? await sut.run(with: state)

        XCTAssertEqual(
            fileManager.contentsAtPath,
            ["/some/custom/path/muter.conf.yml", "\(fixturesDirectory)/\(TriageFile.fileName)"]
        )
    }

    // #122: a misspelled key was dropped without a word.
    func test_unknownKeys_areSent_withTheFilesName_andTheRunGoesOn() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeOut: 120\n".utf8
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(sent.events.count, 1)
        XCTAssertEqual(sent.events.first?.file, MuterConfiguration.fileNameWithExtension)
        XCTAssertEqual(sent.events.first?.keys, [.init(key: "mutationTestTimeOut", closest: "mutationTestTimeout")])
        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertNil(configuration.testSuiteTimeout)
    }

    // So a misspelled required key is named, besides the error that it's missing.
    func test_unknownKeys_areSent_evenWhenTheFileIsRefused() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("executible: /usr/bin/swift\narguments: [test]\n".utf8)

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("executable"), reason)
        }

        XCTAssertEqual(sent.events.first?.keys, [.init(key: "executible", closest: "executable")])
    }

    // Converting it would drop the key the warning names, and the next run would say nothing of it: it is kept, with
    // its name in the warning, until the key is fixed.
    func test_aLegacyFileWithAnUnknownKey_isNamed_andNotConverted() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = Data(
            #"{"executable": "/usr/bin/swift", "arguments": ["test"], "mutationTestTimeOut": 120}"#.utf8
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent.events.first?.file, MuterConfiguration.legacyFileNameWithExtension)
        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }

    // So it isn't taken for the project's own `muter.conf.yml`.
    func test_aConfigurationFileElsewhere_isNamedByItsPath() async throws {
        let sent = recordedUnknownKeys()
        let file = Data("executable: /usr/bin/swift\narguments: [test]\ncolour: blue\n".utf8)

        for folder in ["\(fixturesDirectory)/ci", "/elsewhere/ci.yml"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = file
            state.runOptions = .make(configurationURL: URL(fileURLWithPath: folder))
            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(sent.events.map(\.file), ["ci/\(MuterConfiguration.fileNameWithExtension)", "/elsewhere/ci.yml"])
    }

    // What an earlier version wrote for any value but these, and then ignored, as it is now.
    func test_buildSystemUnknown_isTakenAsUnset() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nbuildSystem: unknown\n".utf8
        )

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertNil(configuration.explicitBuildSystem)
    }

    func test_noUnknownKey_sendsNothing() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertTrue(sent.events.isEmpty)
    }

    // 0 was a limit of no time for every mutant, and below 0 trapped.
    func test_aTimeoutNotAboveZero_isRefused() async throws {
        for value in ["0", "-5"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeout: \(value)\n".utf8
            )

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(
                    reason,
                    "mutationTestTimeout must be a number of seconds above 0, and at most a day (86400), not \(value)."
                )
            }
        }
    }

    // It was taken as 1.
    func test_noWorkers_isRefused() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestWorkers: 0\n".utf8
        )

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error,
                .configurationParsingError(reason: "mutationTestWorkers must be a whole number, at least 1, not 0.")
            )
        }
    }

    // Each would break a call SwiftMutator makes with them: its build for testing, a mutant's run from the
    // `.xctestrun`, the coverage run, or the runs after the first that writes a result bundle.
    func test_xcodebuildArgumentsThatBreakSwiftMutatorsOwnCalls_areRefused_namingTheArgument() async throws {
        let refused: [(arguments: String, named: String)] = [
            ("[-destination, platform=macOS, build-for-testing]", "`build-for-testing` in `arguments`"),
            ("[-destination, platform=macOS, test-without-building]", "`test-without-building` in `arguments`"),
            ("[-destination, platform=macOS, analyze, test]", "`analyze` in `arguments` isn't an action"),
            ("[-destination, platform=macOS, archive]", "`archive` in `arguments` isn't an action"),
            ("[-xctestrun, App.xctestrun, -destination, platform=macOS, test]", "`-xctestrun` in `arguments`"),
            ("[-destination, platform=macOS, -testProductsPath, a.xctestproducts, test]", "`-testProductsPath`"),
            ("[-destination, platform=macOS, -resultBundlePath, out.xcresult, test]", "`-resultBundlePath`"),
            ("[-destination, platform=macOS, -enumerate-tests, test]", "`-enumerate-tests`"),
        ]
        for (arguments, named) in refused {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data("executable: /usr/bin/xcodebuild\narguments: \(arguments)\n".utf8)

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(reason.hasPrefix(named), "\(arguments): \(reason)")
            }
        }
    }

    func test_aBuildForTestingAction_isRefused_sayingWhatToDoInstead() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, build-for-testing]\n".utf8
        )

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error, .configurationParsingError(
                reason: "`build-for-testing` in `arguments` is an action SwiftMutator runs itself: it builds once with "
                    + "`build-for-testing`, then tests each mutant with `test-without-building`. Give `test` as the "
                    + "action instead."
            ))
        }
    }

    // A wrapper script is given the same arguments as xcodebuild.
    func test_aWrapperScriptForXcodebuild_hasItsArgumentsChecked() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("""
        executable: /project/ci/run-tests.sh
        buildSystem: xcodebuild
        arguments: [-destination, platform=macOS, -xctestrun, App.xctestrun, test-without-building]
        """.utf8)

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.hasPrefix("`-xctestrun` in `arguments`"), reason)
        }
    }

    // `clean test` cleans before the baseline and `build test` builds before it; a value that reads like an action, as
    // `-scheme archive`, is a value. The coverage run's `-enableCodeCoverage` replaces the test command's. Other build
    // systems' arguments aren't xcodebuild's.
    func test_argumentsThatSwiftMutatorsCallsTake_areLetThrough() async throws {
        let accepted = [
            "executable: /usr/bin/xcodebuild\narguments: [-scheme, archive, -destination, platform=macOS, clean, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, build, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, -enableCodeCoverage, NO, test]",
            "executable: /usr/bin/xcodebuild\narguments: [-destination, platform=macOS, -only-testing:AppTests, test]",
            "executable: /usr/bin/swift\narguments: [build, test, -enableCodeCoverage]",
        ]
        for yaml in accepted {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(yaml.utf8)

            let result = try await sut.run(with: state)

            guard case .configurationParsed? = result.last else {
                XCTFail("\(yaml): \(result)")
                return
            }
        }
    }

    // The flags take their place, so the run never uses them.
    func test_aTimeoutAndWorkersOutOfRange_areLetThrough_whenTheFlagsReplaceThem() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeout: 0\nmutationTestWorkers: 0\n".utf8
        )
        state.runOptions = .make(workers: 2, timeout: 60)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.testSuiteTimeout, 60)
        XCTAssertEqual(configuration.mutationTestWorkers, 2)
    }

    /// Each `configurationKeysUnknown` from now on.
    private func recordedUnknownKeys() -> RecordedUnknownKeys {
        let recorded = RecordedUnknownKeys()
        let observer = runEvents.observe(.configurationKeysUnknown) { event in
            if let sent = event.object as? ([UnknownConfigurationKey], String) {
                recorded.events.append((keys: sent.0, file: sent.1))
            }
        }
        addTeardownBlock { observer.cancel() }
        return recorded
    }

    private final class RecordedUnknownKeys {
        var events: [(keys: [UnknownConfigurationKey], file: String)] = []
    }

    private func loadJSONConfiguration() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        )
    }

    private func loadYAMLConfiguration() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"
        )
    }

    private func loadYAMLConfigurationWithoutDestination() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/muter.conf.withoutDestination.yml"
        )
    }
}
