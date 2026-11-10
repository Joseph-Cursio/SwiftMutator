import Foundation
@testable import muterCore
import XCTest

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
