#if !os(Linux)
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension BuildForTestingTests {
    // A mutant that doesn't compile: the next build leaves it out, and takes no `clean`, so only its file builds again.
    func test_buildForTestingFailsOnAMutant_thenBuildAgainWithoutIt_andGiveItToTheRun() async throws {
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
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "S", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/temp")
        state.mutationMapping = [mapping]
        state.preparedSources = [path: prepared]
        state.loggingDirectory = "/logs"
        let failed = "\(path):\(lineWithIt + 2):9: error: no such operator\n"
        scriptBuilds([built(failed, status: 65), built()])
        fileManager.contentsAtPathSortedToReturn = ["some/project.xctestrun"]
        fileManager.fileContentsToReturn = loadXCTestRun()

        let result = try await sut.run(with: state)

        let builds = buildsRun
        XCTAssertEqual(builds.count, 2, "\(builds)")
        XCTAssertTrue(builds[0].contains("clean"))
        XCTAssertFalse(builds[1].contains("clean"))
        XCTAssertTrue(builds[1].contains("build-for-testing"))
        XCTAssertFalse(writeFile.contentPassed?.contains("\"\(bad)\"") ?? true)
        XCTAssertEqual(fileManager.createdFiles["/logs/failed build 1.log"], Data(failed.utf8))
        XCTAssertTrue(
            result.contains { change in
                if case let .mutantsLeftOutOfTheBuild(mutants) = change { return Array(mutants.keys) == [bad] }
                return false
            },
            "\(result)"
        )
    }

    // The value of `-scheme` isn't the `clean` the first build adds.
    func test_rebuildArguments_takeOutOnlyTheCleanTheBuildAdds() {
        let configuration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "clean", "test"]
        )

        XCTAssertEqual(configuration.buildForTestingArguments.suffix(2), ["clean", "build-for-testing"])
        XCTAssertEqual(configuration.rebuildForTestingArguments.last, "build-for-testing")
        XCTAssertEqual(configuration.rebuildForTestingArguments.filter { $0 == "clean" }.count, 1)
        XCTAssertTrue(configuration.rebuildForTestingArguments.contains("-scheme"))
    }
}
#endif
