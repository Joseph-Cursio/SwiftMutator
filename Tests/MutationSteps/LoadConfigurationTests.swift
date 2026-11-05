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

        guard case let .configurationParsed(configuration)? = result.last else { return XCTFail("\(result)") }
        XCTAssertEqual(configuration.mutationTestWorkers, 6)
        XCTAssertEqual(configuration.testSuiteTimeout, 45.5)
        let fromFile = try XCTUnwrap(MuterConfiguration.fromFixture(
            at: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        ))
        XCTAssertEqual(configuration.overriding(workers: nil, timeout: nil), configuration)
        XCTAssertEqual(fromFile.overriding(workers: 6, timeout: 45.5), configuration)
        XCTAssertNotEqual(fromFile, configuration)
    }

    // As --workers and --timeout do: the header records it, and a resume only says it changed.
    func test_failUnderFlag_replacesItsKey() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()
        state.runOptions = .make(failUnder: 72.5)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else { return XCTFail("\(result)") }
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
            return XCTFail("Could not assert configurations")
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
