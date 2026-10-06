@testable import muterCore
import TestingExtensions
import XCTest

final class XcodeReporterTests: ReporterTestCase {
    override func setUp() {
        super.setUp()

        outcomes.append(contentsOf: [
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file4.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                ),
                originalProjectDirectoryUrl: URL(string: "/user/project")!
            ),
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file5.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                ),
                originalProjectDirectoryUrl: URL(string: "/user/project")!
            ),
        ])
    }

    func test_report() {
        let actualReport = XcodeReporter()
            .report(
                from: .make(mutations: outcomes)
            )

        XCTAssertEqual(
            actualReport,
            """
            Mutation score: 33
            Mutants introduced into your code: 3
            Number of killed mutants: 1
            """
        )
    }

    func test_report_withSuspects_addsTheScoreAndOneWarningLine() throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        // timing() failed for a mutant in each of 10 files: alone in the first 4.
        let kills = (1 ... 10).map { file in
            let focused = FailedTestLine.FailedTest(name: "focused\(file)()", location: "File\(file)Tests.swift:3:5")
            let tests = [timing] + (file > 4 ? [focused] : [])
            return MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/project/File\(file).swift", position: 3),
                killingTests: .init(tests: tests, count: tests.count, isComplete: true)
            )
        }

        let actualReport = XcodeReporter().report(from: .make(mutations: outcomes + kills))

        XCTAssertEqual(
            actualReport,
            """
            Mutation score: 84
            Mutants introduced into your code: 13
            Number of killed mutants: 11
            Mutation score without suspect tests: 53
            warning: SwiftMutator: 1 test may fail whatever the mutant: it failed for mutants in at least 15% of the \
            10 files with a killed mutant (timing() in 10). Without its failures, the mutation score would be 53%, \
            not 84%.
            """
        )
        // Xcode lists it without a location: no line of the summary is a file's warning.
        let fileWarning = try NSRegularExpression(pattern: "\\.swift:[0-9]+:[0-9]+: warning:")
        let wholeReport = NSRange(actualReport.startIndex..., in: actualReport)
        XCTAssertNil(fileWarning.firstMatch(in: actualReport, range: wholeReport))
        XCTAssertEqual(actualReport.components(separatedBy: "\n").filter { $0.hasPrefix("warning: ") }.count, 1)
    }

    func test_report_whenTheScoreWithoutSuspectsIsALowerBound_saysAtLeast() {
        // The suspect-only kill in file 12 stopped at its first failed test, so another test may have failed for it.
        let actualReport = XcodeReporter().report(from: .withSuspectTests)

        XCTAssertEqual(
            actualReport,
            """
            Mutation score: 92
            Mutants introduced into your code: 14
            Number of killed mutants: 13
            Mutation score without suspect tests: at least 50
            warning: SwiftMutator: 2 tests may fail whatever the mutant: they failed for mutants in at least 15% of \
            the 12 files with a killed mutant (timing() in 12, order() in 10). Without their failures, the mutation \
            score would be at least 50%, not 92%.
            """
        )
    }
}
