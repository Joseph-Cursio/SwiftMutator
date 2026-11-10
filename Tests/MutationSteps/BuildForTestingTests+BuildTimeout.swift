#if !os(Linux)
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension BuildForTestingTests {
    // Each build runs under buildTimeout. One stopped there stops the run, as a failed baseline does, naming the
    // step, the limit and the log, and its compile errors, cut short, take no mutant out to build again.
    func test_aBuildPastTheBuildTimeout_stopsTheRun_withoutBuildingAgain() async throws {
        let path = "/path/to/temp/Sources/Check.swift"
        let prepared = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["-scheme", "S", "test"], buildTimeout: 900
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        let cutShort = "Compiling Check.swift\n\(path):3:9: error: no such operator\n"
        scriptBuilds([
            CommandResult(status: 9, endedBySignal: true, output: cutShort, errors: "", timedOut: true),
            built(),
        ])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 900, output: cutShort, log: "/logs/failed build 1.log"
            ))
        )
        XCTAssertEqual(buildsRun.count, 1)
        XCTAssertEqual(process.timeLimits, [900])
        XCTAssertEqual(fileManager.createdFiles["/logs/failed build 1.log"], Data(cutShort.utf8))
        XCTAssertNil(writeFile.contentPassed)
    }

    // Each build has the whole limit: the one after taking out a mutant that doesn't compile too.
    func test_aBuildAgainPastTheBuildTimeout_stopsTheRun_withItsOwnLog() async throws {
        let path = "/path/to/temp/Sources/Check.swift"
        let prepared = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        let bad = try XCTUnwrap(mapping.mutationSchemata.first?.id)
        let rewritten = MuterRewriter(mapping).visit(source.code).description
        let lineWithIt = try XCTUnwrap(
            rewritten.components(separatedBy: "\n").firstIndex { $0.contains("\"\(bad)\"") }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["-scheme", "S", "test"], buildTimeout: 900
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        scriptBuilds([
            built("\(path):\(lineWithIt + 2):9: error: no such operator\n", status: 65),
            CommandResult(status: 9, endedBySignal: true, output: "Compiling\n", errors: "", timedOut: true),
        ])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 900, output: "Compiling\n", log: "/logs/failed build 2.log"
            ))
        )
        XCTAssertEqual(process.timeLimits, [900, 900])
    }

    // A build stopped before it printed anything is stopped at its limit, not a command that couldn't run.
    func test_aBuildPastTheBuildTimeout_thatPrintedNothing_isStillReportedAsStopped() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild", arguments: ["test"], buildTimeout: 30
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        scriptBuilds([CommandResult(status: 9, endedBySignal: true, output: "", errors: "", timedOut: true)])

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .buildForTesting, seconds: 30, output: "", log: nil
            ))
        )
    }
}
#endif
