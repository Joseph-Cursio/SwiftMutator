import Foundation
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class LoadMuterTestPlanTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = LoadMuterTestPlan()
    private let testPlanPath = "/path/to/test-plan"

    func test_whenThereIsNotTestPlanUrl_thenThrowError() async throws {
        state.runOptions = .make(testPlanURL: nil)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: "Could not load the test plan")
        )
    }

    func test_whenCannotLoadTestPlan_thenThrowError() async throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/path/to/test-plan"))

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: "Could not load the test plan at path: /path/to/test-plan")
        )
    }

    func test_loadMuterTestPlan() async throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/path/to/test-plan"))
        fileManager.fileContentsToReturn = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/muted",
            projectCoverage: 23
        ).toData

        let result = try await sut.run(with: state)

        XCTAssertEqual(
            result, [
                .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/muted")),
                .projectCoverage(.init(percent: 23)),
                .mutationMappingsDiscovered([]),
            ]
        )
    }

    // Another run of the project may be removing or rewriting the mutated project until it is locked, which comes
    // after this step: only the plan itself is read.
    func test_readsNothingInTheMutatedProject() async throws {
        let mapping = try XCTUnwrap(
            generateSchemataMappings(
                for: SourceCodeInfo(
                    path: "/path/to/muted/Sources/Check.swift",
                    code: Parser.parse(source: "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n")
                )
            ).first
        )
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        fileManager.fileContentsToReturn = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/muted",
            mappings: [mapping]
        ).toData

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/muted")))
        XCTAssertEqual(fileManager.contentsAtPath, [testPlanPath])
    }
}
