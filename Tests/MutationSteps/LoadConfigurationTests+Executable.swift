@testable import muterCore
import XCTest
import Yams

extension LoadConfigurationTests {
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
}
