import Foundation
@testable import muterCore
import TestingExtensions
import XCTest

/// The check that xcodebuild's build left every mutant in it its switch (`CheckMutantSwitchesAfterTheBuild`).
extension CheckMutantSwitchesTests {
    func test_afterTheBuild_whenEveryMutantKeepsItsSwitch_thenItPasses() throws {
        let file = try mutatedFile(named: "Check")
        state.muterConfiguration = xcodebuild
        state.mutationMapping = [file.mapping]
        queueCode(file.rewritten)

        XCTAssertEqual(try CheckMutantSwitchesAfterTheBuild().run(with: state), [])
        XCTAssertEqual(fileManager.contentsAtPath, [file.mapping.filePath])
    }

    // A Run Script phase that generates the file wrote it again, without the switches.
    func test_afterTheBuild_whenABuildStepRewroteAFile_thenThrowErrorNamingIt() async throws {
        let file = try mutatedFile(named: "Check")
        state.muterConfiguration = xcodebuild
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/muted")
        state.mutationMapping = [file.mapping]
        queueCode(file.original)

        try await assertThrowsMuterError(CheckMutantSwitchesAfterTheBuild().run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            let count = file.mapping.mutationSchemata.count
            XCTAssertTrue(reason.contains("the build rewrote a file SwiftMutator had mutated, and \(count) mutants"))
            XCTAssertTrue(reason.contains("\n  Sources/Check.swift lost the switches of \(count) of its"), reason)
            XCTAssertTrue(reason.contains("`exclude: [\"/Sources/Check.swift\"]`"), reason)
            XCTAssertTrue(reason.contains("`[ \"$SWIFTMUTATOR\" = YES ] && exit 0`"), reason)
            XCTAssertFalse(reason.contains("mutate-without-running"), reason)
            XCTAssertFalse(reason.contains("bug"), reason)
        }
    }

    // `run-without-mutating` reads no `exclude`, and the build rewrote the plan's copy.
    func test_afterTheBuild_ofATestPlan_sayToMakeThePlanAgain() async throws {
        let file = try mutatedFile(named: "Check")
        state.muterConfiguration = xcodebuild
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        state.mutationMapping = [file.mapping]
        queueCode(file.original)

        try await assertThrowsMuterError(CheckMutantSwitchesAfterTheBuild().run(with: state)) { error in
            guard case let .literal(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("make the test plan again with `swift-mutator mutate-without-running`"))
        }
    }

    // `CompileRecovery` took them out of the code itself; a file it left with none isn't read.
    func test_afterTheBuild_mutantsTakenOutOfTheBuild_areNotMissed() throws {
        let file = try mutatedFile(named: "Check")
        let takenOut = try XCTUnwrap(file.mapping.mutationSchemata.last)
        let allTakenOut = try mutatedFile(named: "AllOut")
        let leftOut = LeftOutMutant(blame: .itself, errors: [], buildLog: "build-1.log")
        state.muterConfiguration = xcodebuild
        state.mutationMapping = [file.mapping, allTakenOut.mapping]
        state.mutantsLeftOut = Dictionary(
            ([takenOut] + allTakenOut.mapping.mutationSchemata).map { ($0.id, leftOut) }
        ) { first, _ in first }
        queueCode(file.rewritten.replacingOccurrences(of: "\"\(takenOut.id)\"", with: "\"\""))

        XCTAssertEqual(try CheckMutantSwitchesAfterTheBuild().run(with: state), [])
        XCTAssertEqual(fileManager.contentsAtPath, [file.mapping.filePath])
    }

    // `swift test`'s build plugins write in its build folder; a wrapper builds with each mutant's run.
    func test_afterTheBuild_onlyAnXcodebuildBuildIsChecked() throws {
        let file = try mutatedFile(named: "Check")
        state.mutationMapping = [file.mapping]
        queueCode(file.original)

        for executable in ["/usr/bin/swift", "./test.sh"] {
            state.muterConfiguration = MuterConfiguration(executable: executable, arguments: ["test"])
            XCTAssertEqual(try CheckMutantSwitchesAfterTheBuild().run(with: state), [])
        }
        XCTAssertEqual(fileManager.contentsAtPath, [])
    }

    private var xcodebuild: MuterConfiguration {
        MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["-scheme", "App", "test"])
    }
}
