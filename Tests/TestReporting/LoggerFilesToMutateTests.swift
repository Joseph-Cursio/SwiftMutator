@testable import muterCore
import Rainbow
import XCTest

final class LoggerFilesToMutateTests: MuterTestCase {
    private let sut = Logger()

    func test_filesToMutateUnmatched_saysWhyForEachEntry() {
        sut.filesToMutateUnmatched([
            .init(entry: "Sources/Missing.swift", reason: .noSwiftFile),
            .init(entry: "../Other.swift", reason: .outsideTheProject),
            .init(entry: "Tests", reason: .excluded),
            .init(entry: "Package.swift", reason: .neverMutated),
            .init(entry: "Example", reason: .withoutCoverage),
        ])

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ --files-to-mutate Sources/Missing.swift names no Swift file.",
            "⚠️ --files-to-mutate ../Other.swift names only Swift files outside the project.",
            "⚠️ --files-to-mutate Tests names only files the excludes leave out; an \("exclude".bold) entry that "
                + "starts with ! keeps them.",
            "⚠️ --files-to-mutate Package.swift names only package manifests or files in build folders, which are "
                + "never mutated.",
            "⚠️ --files-to-mutate Example names only files the excludes or the coverage filter leave out: those at or "
                + "below \("coverageThreshold".bold), which by default are those whose code no test ran.",
        ])
    }

    func test_timedTestRunStopped_saysTheLimit_andWhereItsLogIs() {
        sut.timedTestRunStopped(seconds: 60, log: "/logs/timed test run.log")
        sut.timedTestRunStopped(seconds: 90.5, log: nil)

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ The timed test run, with no mutant on, didn't end within 60 s, so SwiftMutator stopped it, and takes "
                + "each mutant's time limit from the baseline instead. Its log is in /logs/timed test run.log.",
            "⚠️ The timed test run, with no mutant on, didn't end within 90.5 s, so SwiftMutator stopped it, and takes "
                + "each mutant's time limit from the baseline instead.",
        ])
    }
}
