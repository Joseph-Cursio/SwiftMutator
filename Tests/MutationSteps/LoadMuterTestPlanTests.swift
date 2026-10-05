import Foundation
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class LoadMuterTestPlanTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = LoadMuterTestPlan()
    private let testPlanPath = "/path/to/test-plan"
    private let swiftTest = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])

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

    // A `swift test` run names its mutant in the file `activeMutantFileKey` names. The cache PR #13 generated
    // only reads each mutant's own variable, so every mutant of such a plan would survive.
    func test_whenASwiftPackagePlansCodePredatesTheActiveMutantFile_thenThrowError() async throws {
        let file = try mutatedCheck(named: "Check")
        queuePlan(testedWith: swiftTest, file.mapping)
        queueCode("""
        func check(_ value: Int) -> Bool {
            if __SwiftMutator.environment["\(file.identifier)"] != nil {
                return value >= 1
            } else {
                return value > 1
            }
        }

        fileprivate enum __SwiftMutator {
            static let environment = ProcessInfo.processInfo.environment
        }

        """)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: LoadMuterTestPlan.codePredatesTheActiveMutantFile("/path/to/muted"))
        )
        let reason = LoadMuterTestPlan.codePredatesTheActiveMutantFile("/path/to/muted")
        XCTAssertTrue(reason.contains("/path/to/muted"), reason)
        XCTAssertTrue(reason.contains("`swift-mutator mutate-without-running`"), reason)
    }

    // Before PR #13, each switch read its mutant's own variable straight from the live environment.
    func test_whenASwiftPackagePlansCodePredatesTheEnvironmentCache_thenThrowError() async throws {
        let file = try mutatedCheck(named: "Check")
        queuePlan(testedWith: swiftTest, file.mapping)
        queueCode("""
        func check(_ value: Int) -> Bool {
            if ProcessInfo.processInfo.environment["\(file.identifier)"] != nil {
                return value >= 1
            } else {
                return value > 1
            }
        }

        """)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: LoadMuterTestPlan.codePredatesTheActiveMutantFile("/path/to/muted"))
        )
    }

    func test_whenASwiftPackagePlansCodeReadsTheActiveMutantFile_thenItLoads() async throws {
        let file = try mutatedCheck(named: "Check")
        queuePlan(testedWith: swiftTest, file.mapping)
        queueCode(file.rewritten)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/muted")))
    }

    // A file can hold no switch although its mapping has mutants, if it couldn't be rewritten. It says
    // nothing about the SwiftMutator that made the plan, so the next file decides.
    func test_aFileWithoutItsSwitchSettlesNothing() async throws {
        let first = try mutatedCheck(named: "First")
        let second = try mutatedCheck(named: "Second")
        queuePlan(testedWith: swiftTest, first.mapping, second.mapping)
        queueCode(first.original)
        queueCode(second.rewritten)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/muted")))
        XCTAssertEqual(fileManager.contentsAtPath, [testPlanPath, first.mapping.filePath, second.mapping.filePath])
    }

    // xcodebuild runs still switch each mutant on through its own variable, which old code reads too.
    func test_anXcodebuildPlanMadeBeforeTheActiveMutantFileStillLoads() async throws {
        let file = try mutatedCheck(named: "Check")
        queuePlan(
            testedWith: MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]),
            file.mapping
        )
        queueCode("""
        func check(_ value: Int) -> Bool {
            if ProcessInfo.processInfo.environment["\(file.identifier)"] != nil {
                return value >= 1
            } else {
                return value > 1
            }
        }

        """)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/muted")))
        XCTAssertEqual(fileManager.contentsAtPath, [testPlanPath])
    }

    // MARK: - Helpers

    private struct MutatedFile {
        let mapping: SchemataMutationMapping
        let identifier: String
        let original: String
        let rewritten: String
    }

    /// A file of the mutated project holding one mutant, before and after this SwiftMutator inserts its switch.
    private func mutatedCheck(named name: String) throws -> MutatedFile {
        let source = SourceCodeInfo(
            path: "/path/to/muted/Sources/\(name).swift",
            code: Parser.parse(source: """
            func check(_ value: Int) -> Bool {
                return value > 1
            }

            """)
        )
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        let identifier = try XCTUnwrap(mapping.mutationSchemata.first).id

        return MutatedFile(
            mapping: mapping,
            identifier: identifier,
            original: source.code.description,
            rewritten: MuterRewriter(mapping).rewrite(source.code).description
        )
    }

    /// Queues a plan of the given files, to be read first. Queue each file's code after it, in the same order.
    private func queuePlan(testedWith configuration: MuterConfiguration, _ mappings: SchemataMutationMapping...) {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.muterConfiguration = configuration
        fileManager.fileContentsToReturn = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/muted",
            mappings: mappings
        ).toData
    }

    private func queueCode(_ code: String) {
        fileManager.fileContentsToReturn = Data(code.utf8)
    }
}
