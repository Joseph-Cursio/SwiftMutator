@testable import muterCore
import XCTest
import Yams

final class LoadConfigurationTests: MuterTestCase {
    lazy var currentDirectory = fixturesDirectory
    lazy var sut = LoadConfiguration()
    var state = MutationTestState()

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

    func assertConfigurationsEquals(
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

    func loadJSONConfiguration() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/\(MuterConfiguration.legacyFileNameWithExtension)"
        )
    }

    func loadYAMLConfiguration() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/\(MuterConfiguration.fileNameWithExtension)"
        )
    }

    func loadYAMLConfigurationWithoutDestination() -> Data? {
        FileManager.default.contents(
            atPath: "\(fixturesDirectory)/muter.conf.withoutDestination.yml"
        )
    }
}
