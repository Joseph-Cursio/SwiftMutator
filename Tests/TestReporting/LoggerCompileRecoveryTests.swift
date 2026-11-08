import Foundation
@testable import muterCore
import XCTest

/// What the console says of mutants that don't compile (`CompileRecovery`).
final class LoggerCompileRecoveryTests: MuterTestCase {
    private let sut = Logger()

    // No switch for it is in the copy, so there is nothing to run its tests with.
    func test_oneMutantTested_ofOneLeftOutOfTheBuild_saysSo_andNotHowToSwitchItOn() throws {
        var run = OneMutantRun.make(outcome: .buildError)
        run.leftOutOfTheBuild = true

        sut.oneMutantTested(run, reports: [])

        let lines = printer.linesPassed
        XCTAssertTrue(lines.contains("Verdict: didn't compile, so its tests didn't run"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Mutated project kept, without the mutant: ") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("To run its tests with it on") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("with the mutant switched off") }, "\(lines)")
    }

    func test_buildingAgainWithoutMutants_blamesNoOneYet() {
        sut.buildingAgainWithoutMutants(count: 1)
        sut.buildingAgainWithoutMutants(count: 3)

        XCTAssertEqual(printer.linesPassed, [
            "🔁 The build failed where 1 mutant is, so SwiftMutator is building again without it.",
            "🔁 The build failed where 3 mutants are, so SwiftMutator is building again without them.",
        ])
    }

    func test_mutantsLeftOutOfTheBuild_namesThem_upToItsLimit_andSaysWhenNoneIsLeft() throws {
        func mutants(_ count: Int) -> [MutantsLeftOut.Mutant] {
            (1 ... count).map { line in
                MutantsLeftOut.Mutant(
                    key: MutantKey(path: "A.swift", mutationOperatorId: .ror, line: line, column: 3, occurrence: 0),
                    change: "changed < to >",
                    mutant: LeftOutMutant(
                        blame: .itself,
                        errors: [CompilerError(filePath: "/A.swift", line: 90, column: 3, message: "no such operator")],
                        buildLog: "failed build 1.log"
                    )
                )
            }
        }

        sut.mutantsLeftOutOfTheBuild(MutantsLeftOut(mutants: mutants(1), toTest: 4))
        sut.mutantsLeftOutOfTheBuild(MutantsLeftOut(mutants: mutants(MutantsLeftOut.namedAtMost + 2), toTest: 0))

        let one = try XCTUnwrap(printer.linesPassed.first)
        XCTAssertTrue(one.hasPrefix("⚠️ 1 mutant doesn't compile, so SwiftMutator took it out of the build"), one)
        XCTAssertTrue(one.contains("The score leaves it out, the reports list it as a build error"), one)
        XCTAssertTrue(
            one.contains("\n  A.swift:1:3 RelationalOperatorReplacement (changed < to >): no such operator"),
            one
        )
        XCTAssertFalse(one.contains("That leaves no mutant"), one)
        let many = try XCTUnwrap(printer.linesPassed.last)
        XCTAssertTrue(many.hasPrefix("⚠️ 12 mutants don't compile"), many)
        XCTAssertTrue(many.contains("A.swift:10:3"), many)
        XCTAssertFalse(many.contains("A.swift:11:3"), many)
        XCTAssertTrue(many.contains("… and 2 more: each one's log says why"), many)
        XCTAssertTrue(many.hasSuffix("⚠️ That leaves no mutant to test."), many)
    }

    // Those it left out never ran, so "after testing" doesn't count them.
    func test_mutationTestingEndedEarly_countsMutantsLeftOutApartFromThoseTested() {
        var end = EarlyEnd.make(tested: [.failed, .buildError, .buildError], discovered: 9)
        end.leftOut = 2

        sut.mutationTestingEndedEarly(end, partialReports: [], resultsFile: nil, continueCommand: nil)

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by a signal after testing 1 of 9 mutants. 2 more were taken out of the build. "
                + "Mutation score so far: 100%.",
        ])
    }

    func test_aRunsEnd_warnsOfItsBuildErrors() {
        sut.mutationTestingFinished(
            report: "",
            reportPath: "",
            isExportingReport: false,
            didSaveReport: false,
            scoreLine: "",
            suspectWarning: nil,
            buildErrorWarning: MutationTestOutcome(mutations: [.make(testSuiteOutcome: .buildError)]).buildErrorWarning
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ 1 mutant was a build error, so it wasn't tested, and the score leaves it out."
        )
    }

    func test_buildErrorWarning_isNilWithoutAny_andForOneMutantsRun() {
        XCTAssertNil(MutationTestOutcome(mutations: [.make(testSuiteOutcome: .failed)]).buildErrorWarning)
        XCTAssertNil(
            MutationTestOutcome(mutations: [.make(testSuiteOutcome: .buildError)], mutant: "A.swift:1:2 ROR")
                .buildErrorWarning
        )
        XCTAssertEqual(
            MutationTestOutcome(mutations: [.make(testSuiteOutcome: .buildError), .make(testSuiteOutcome: .buildError)])
                .buildErrorWarning,
            "2 mutants were build errors, so they weren't tested, and the score leaves them out."
        )
    }
}

/// What the reports say of mutants that weren't tested, as they were build errors.
final class ReportsOfMutantsNotTestedTests: MuterTestCase {
    private let error = CompilerError(filePath: "/A.swift", line: 1, column: 1, message: "no such operator")

    func test_theWarning_saysHowManyWentWithOthers_whateverTheListLeavesOut() throws {
        let sut = Logger()
        let mutants = (1 ... MutantsLeftOut.namedAtMost + 2).map { line in
            MutantsLeftOut.Mutant(
                key: MutantKey(path: "A.swift", mutationOperatorId: .ror, line: line, column: 3, occurrence: 0),
                change: "",
                mutant: LeftOutMutant(
                    blame: line > MutantsLeftOut.namedAtMost ? .itsFile : .itself,
                    errors: [error],
                    buildLog: "log"
                )
            )
        }

        sut.mutantsLeftOutOfTheBuild(MutantsLeftOut(mutants: mutants, toTest: 1))

        let said = try XCTUnwrap(printer.linesPassed.last)
        XCTAssertTrue(said.hasPrefix("⚠️ SwiftMutator took 12 mutants out of the build"), said)
        XCTAssertTrue(said.contains("pinned on 10, and 2 went with others"), said)
        XCTAssertFalse(said.contains("12 mutants don't compile"), said)
    }

    func test_stoppingAtTheMostBuilds_saysTheErrorsMayStillBeMutants() {
        Logger().stoppedTakingOutMutants(afterBuilds: 20)

        XCTAssertTrue(printer.linesPassed.last?.contains("after at most 20 failed builds") ?? false)
        XCTAssertTrue(printer.linesPassed.last?.contains("may still be mutants'") ?? false)
    }

    func test_theXcodeFormat_listsTheirWarningAsAnIssue() {
        let report = XcodeReporter().report(
            from: MutationTestOutcome(mutations: [.make(testSuiteOutcome: .buildError)])
        )

        XCTAssertTrue(
            report.hasSuffix("\nwarning: SwiftMutator: 1 mutant was a build error, so it wasn't tested, and the score "
                + "leaves it out."),
            report
        )
    }

    func test_summaryJSON_hasNoScore_whenEveryMutantWasABuildError() {
        let summary = RunSummary(
            of: MutationTestOutcome(mutations: [.make(testSuiteOutcome: .buildError)]),
            ended: .finished,
            report: nil
        )

        XCTAssertNil(summary.mutationScore)
    }

    func test_aSampleWithNothingScored_hasNoMargin_andSaysSo() throws {
        let selection = SampleSelection(size: 1, seed: 3, mutantsSampledFrom: 4, mutantsSampled: 1)

        let scope = try XCTUnwrap(SampleScope(selection, killed: 0, scored: 0, tested: 1, cutShort: false))

        XCTAssertNil(scope.marginOfError)
        XCTAssertTrue(scope.sentence.contains("every one with a result was a build error"), scope.sentence)
        XCTAssertFalse(scope.sentence.contains("within"), scope.sentence)
    }

    func test_aMergedReportsDetails_comeFromTheFirstShardThatTestedAny() throws {
        let details = try XCTUnwrap(RunDetails(of: [
            ("/a.jsonl", [.make(workers: 0, timeoutSeconds: nil)]),
            ("/b.jsonl", [.make(workers: 4, timeoutSeconds: 24)]),
        ]))

        XCTAssertEqual(details.workers, 4)
        XCTAssertEqual(details.timeoutSeconds, 24)
    }
}
