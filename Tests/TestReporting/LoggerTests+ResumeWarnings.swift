@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    // An earlier result whose mutant this session doesn't discover is dropped without a test, so how many is a warning,
    // with why when coverage says, whether or not anything is left to test; and not "all" the results still hold.
    func test_resumePlanned_warnsOfEarlierResultsNoLongerDiscovered_inBothBranches() {
        sut.resumePlanned(
            .make(
                reused: 1_100,
                toTest: 100,
                retestedBecause: [.notRecorded: 100],
                noLongerDiscovered: 412,
                discoveredBefore: 2_000,
                coverageChange: .gatheredOnlyNow
            )
        )
        sut.resumePlanned(
            .make(reused: 1_200, toTest: 0, retestedBecause: [:], noLongerDiscovered: 1, discoveredBefore: 1_201)
        )
        sut.resumePlanned(
            .make(
                reused: 1,
                toTest: 0,
                retestedBecause: [:],
                noLongerDiscovered: 3,
                discoveredBefore: 4,
                coverageChange: .filesWithoutCoverageChanged
            )
        )

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1100 results still hold, "
                + "so 100 mutants are left to test (100 never tested).",
            "⚠️ 412 earlier results no longer count, as this session doesn't discover their mutants: "
                + "coverage couldn't be gathered then, and is now.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1200 results still hold, so nothing is left to test.",
            "⚠️ 1 earlier result no longer counts, as this session doesn't discover its mutant.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1 result still holds, so nothing is left to test.",
            "⚠️ 3 earlier results no longer count, as this session doesn't discover their mutants: "
                + "the files without coverage changed.",
        ])
    }

    // More mutants than the last session discovered, every earlier result's among them, as when this session couldn't
    // gather coverage, make a run longer than expected. Across a SwiftMutator that discovers differently, which
    // --force-resume let through, coverage says nothing, and neither does the warning.
    func test_resumePlanned_warnsOfAChangedNumberOfMutantsDiscovered_withWhyWhenCoverageSays() {
        sut.resumePlanned(
            .make(
                reused: 1_200,
                toTest: 800,
                retestedBecause: [.notRecorded: 800],
                discoveredBefore: 1_200,
                coverageChange: .gatheredOnlyThen
            )
        )
        sut.resumePlanned(
            .make(
                reused: 0,
                toTest: 1,
                retestedBecause: [.notRecorded: 1],
                discoveredBefore: 3,
                forced: ["swiftMutator.executableSHA256"]
            )
        )

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1200 results still hold, "
                + "so 800 mutants are left to test (800 never tested).",
            "⚠️ This session discovers 2000 mutants, and the last one discovered 1200: "
                + "coverage was gathered then, and couldn't be now.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 0 results still hold, "
                + "so 1 mutant is left to test (1 never tested).",
            "⚠️ This session discovers 1 mutant, and the last one discovered 3.",
            "⚠️ Results are reused although SwiftMutator changed (--force-resume).",
        ])
    }

    // Coverage only the last session had can't have left out a mutant this one discovers, and coverage only this one
    // has can't bring one in, so neither is given as the reason the other way: a deleted file, which --resume-ignoring
    // let through, took its results with it, or the stopped run had tested fewer. Any other way, coverage still says
    // why.
    func test_resumePlanned_givesACoverageChangeAsTheReason_onlyWhenItCanMoveTheCountThatWay() {
        planResumesAfterACoverageChange()

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1100 results still hold, "
                + "so 900 mutants are left to test (900 never tested).",
            "⚠️ 30 earlier results no longer count, as this session doesn't discover their mutants.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 12 results still hold, "
                + "so 3 mutants are left to test (3 never tested).",
            "⚠️ This session discovers 15 mutants, and the last one discovered 12.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 10 results still hold, "
                + "so 5 mutants are left to test (5 never tested).",
            "⚠️ This session discovers 15 mutants, and the last one discovered 20.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 10 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "⚠️ This session discovers 12 mutants, and the last one discovered 20: "
                + "coverage couldn't be gathered then, and is now.",
        ])
    }

    // Coverage that only one session has is warned of even when the mutants are as many: one coverage run failed. A
    // change in coverage both sessions have, with as many mutants, is only said.
    func test_resumePlanned_aCoverageChangeWithAsManyMutants_isAWarningOnlyWhenOneSessionHadNone() {
        sut.resumePlanned(.make(coverageChange: .gatheredOnlyNow))
        sut.resumePlanned(
            .make(reused: 4, toTest: 0, retestedBecause: [:], coverageChange: .percentChanged(was: 78, isNow: 81))
        )
        sut.resumePlanned(.make(coverageChange: .filesWithoutCoverageChanged))

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "⚠️ This session discovers as many mutants as the last one, "
                + "although coverage couldn't be gathered then, and is now.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): all 4 results still hold, "
                + "so nothing is left to test.",
            "ℹ️ Coverage was 78% and is 81% now, but every earlier result's mutant is still discovered.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "ℹ️ The files without coverage changed, but every earlier result's mutant is still discovered.",
        ])
    }

    /// Plans four resumes whose coverage was gathered only then or only now, with more mutants discovered than before
    /// or fewer.
    private func planResumesAfterACoverageChange() {
        sut.resumePlanned(
            .make(
                reused: 1_100,
                toTest: 900,
                retestedBecause: [.notRecorded: 900],
                noLongerDiscovered: 30,
                discoveredBefore: 1_130,
                coverageChange: .gatheredOnlyThen
            )
        )
        sut.resumePlanned(
            .make(
                reused: 12,
                toTest: 3,
                retestedBecause: [.notRecorded: 3],
                discoveredBefore: 12,
                coverageChange: .gatheredOnlyNow
            )
        )
        sut.resumePlanned(
            .make(
                reused: 10,
                toTest: 5,
                retestedBecause: [.notRecorded: 5],
                discoveredBefore: 20,
                coverageChange: .gatheredOnlyThen
            )
        )
        sut.resumePlanned(
            .make(
                reused: 10,
                toTest: 2,
                retestedBecause: [.notRecorded: 2],
                discoveredBefore: 20,
                coverageChange: .gatheredOnlyNow
            )
        )
    }
}
