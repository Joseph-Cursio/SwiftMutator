@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

/// What a `--since` run says: on the console, in its reports, and when it reuses an earlier run's results.
final class SinceReportingTests: MuterTestCase {
    private let selection = ChangeSelection.make(
        ref: "origin/main",
        files: [ChangedFile(path: "Sources/A.swift", sha256: "a"), ChangedFile(path: "Sources/B.swift", sha256: "b")]
    )

    func test_theConsole_saysHowManyFilesChanged_andListsThemOnlyWhenVerbose() {
        Logger().changesSelected(selection)
        Logger().changesSelected(
            .make(changedLines: true, files: [ChangedFile(path: "A.swift", sha256: "")]),
            verbose: true
        )

        XCTAssertEqual(printer.linesPassed, [
            "🌿 2 Swift files changed since the merge base of origin/main and HEAD (ba5e000).",
            "🌿 1 Swift file changed since the merge base of main and HEAD (ba5e000), of which only the changed lines "
                + "are mutated.\n\n" + "A.swift".bold,
        ])
    }

    // A resumed session's command gives the merge base itself, which is said as git abbreviates it.
    func test_theConsole_abbreviatesARefThatIsTheMergeBase() {
        Logger().changesSelected(.make(ref: ChangeSelection.make().mergeBase))

        XCTAssertEqual(
            printer.linesPassed,
            ["🌿 0 Swift files changed since the merge base of ba5e000 and HEAD (ba5e000)."]
        )
    }

    func test_theConsole_namesTheRepositoriesOfTheirOwn_whoseChangesArentCompared() {
        Logger().changesSelected(.make(files: [], foldersNotCompared: ["Packages/Local"]))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ git doesn't compare what is in a folder that is a repository of its "
                + "own, so none of its files is mutated: Packages/Local."
        )
    }

    // The others weren't the run's to test, whichever spelling of the path the coverage tool gave.
    func test_theFilesWithoutCoverage_areOnlyTheChosenOnes() {
        let copy = URL(fileURLWithPath: "/p_mutated")
        let coverage = Coverage(
            percent: 70,
            filesWithoutCoverage: ["/p_mutated/Sources/A.swift", "Sources/B.swift", "/p_mutated/Sources/C.swift"]
        )

        XCTAssertEqual(
            coverage.limited(to: selection, inCopyAt: copy).filesWithoutCoverage,
            ["/p_mutated/Sources/A.swift", "Sources/B.swift"]
        )
        XCTAssertEqual(coverage.limited(to: nil, inCopyAt: copy), coverage)
    }

    func test_theReports_sayWhatWasMutated() throws {
        let outcome = MutationTestOutcome(since: selection)

        XCTAssertTrue(
            PlainTextReporter().report(from: outcome).contains(
                "Only the files changed since the merge base of origin/main and HEAD (ba5e000) were mutated."
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        let since = try XCTUnwrap(json["since"] as? [String: Any])
        XCTAssertEqual(since["ref"] as? String, "origin/main")
        XCTAssertEqual(since["changedLines"] as? Bool, false)
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("Files changed since"))
    }

    func test_aReportWithoutSince_saysNothingOfIt() throws {
        let outcome = MutationTestOutcome()

        XCTAssertFalse(PlainTextReporter().report(from: outcome).contains("changed since the merge base"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        XCTAssertNil(json["since"])
    }

    // A full run's results reused by a --since run: most of them aren't of the mutants it chose, which is no loss.
    func test_aReuseWithAnotherChoice_saysWhy_ratherThanWarning() {
        XCTAssertEqual(
            ResumeSummary.selectionChange(from: nil, to: selection),
            "This run mutates only what changed since the merge base of origin/main and HEAD (ba5e000), so no earlier "
                + "result of another mutant is reused."
        )
        XCTAssertEqual(
            ResumeSummary.selectionChange(from: selection, to: nil),
            "That run mutated only what changed since the merge base of origin/main and HEAD (ba5e000), so this "
                + "run's other mutants have no earlier result."
        )
        XCTAssertNil(
            ResumeSummary.selectionChange(from: selection, to: selection.named("ba5e000", commit: selection.mergeBase))
        )
        XCTAssertNil(ResumeSummary.selectionChange(from: nil, to: nil))

        Logger().resumePlanned(
            .make(noLongerDiscovered: 2400, isReuse: true, selectionChange: "This run mutates only…")
        )

        XCTAssertTrue(printer.linesPassed.contains("ℹ️ This run mutates only…"), "\(printer.linesPassed)")
        XCTAssertFalse(printer.linesPassed.contains { $0.contains("no longer count") }, "\(printer.linesPassed)")
    }
}
