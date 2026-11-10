import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    // Rounded up, so any time left reads as at least 1 min, and in hours once there are 60 minutes. It said "1 minutes"
    // and "2 minute", and gave a long run in minutes alone.
    func test_theTimeLeft_readsInWholeMinutes_andInHoursFromAnHour() {
        let seconds: [TimeInterval] = [0, 1, 60, 61, 3_540, 3_600, 3_660, 7_500, 86_400]

        XCTAssertEqual(seconds.map(SimpleTimeEstimate.text(secondsLeft:)), [
            "0 min", "1 min", "1 min", "2 min", "59 min",
            "1 h", "1 h 1 min", "2 h 5 min", "24 h",
        ])
    }

    // A mutant's run skips the build, which the baseline's time includes, so the timed test run makes a better first
    // estimate: here 10 mutants of 60 s rather than of 600.
    func test_theFirstEstimate_isBasedOnTheTimedTestRun_whenThereIsOne() throws {
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 10).map { _ in try makeSchemataMapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 10, testRunSeconds: 60)
        )

        let draw = printer.linesPassed.last { $0.contains("ETC:") } ?? ""
        XCTAssertTrue(draw.hasSuffix("ETC: 10 min"), draw)
    }

    // Until as many mutants have finished as there are workers, about one each, a rate would count the mutants still
    // running as if none had started, so the first estimate counts down. After that, the time left is the time per
    // mutant so far, over all the workers, times the mutants left.
    func test_theTimeLeft_followsTheAverageRate_onceAsManyMutantsAsWorkersHaveFinished() {
        let secondsLeft = { (tested: Int, elapsed: TimeInterval?) in
            Logger.secondsLeft(tested: tested, of: 10, workers: 2, elapsed: elapsed, firstEstimate: 600)
        }

        XCTAssertEqual(secondsLeft(0, nil), 600) // before the mutants start
        XCTAssertEqual(secondsLeft(0, 100), 500)
        XCTAssertEqual(secondsLeft(1, 150), 450) // one worker is still on its first mutant
        XCTAssertEqual(secondsLeft(2, 200), 800) // 100 s a mutant, and 8 left
        XCTAssertEqual(secondsLeft(4, 200), 300)
        XCTAssertEqual(secondsLeft(10, 900), 0)
        XCTAssertEqual(secondsLeft(1, 900), 0) // a first estimate that ran out says no more than 0
    }

    // The estimate is the rate since the mutants started, not the time since the bar was last drawn times the mutants
    // left, which swung by a factor of 100 when parallel workers finished mutants in bursts.
    func test_theBarsTimeLeft_followsTheRateSinceTheMutantsStarted() throws {
        let milliseconds = Locked<UInt64>(1_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: milliseconds.value * 1_000_000) }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 10).map { _ in try makeSchemataMapping() })
        func lastDraw() -> String { printer.linesPassed.last { $0.contains("ETC:") } ?? "" }

        // 5 mutants a worker, 120 s each.
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 120, remainingMutationPointsCount: 10, workers: 2)
        )
        XCTAssertTrue(lastDraw().hasSuffix("ETC: 10 min"), lastDraw())
        // Building the worker clones isn't time spent on mutants.
        milliseconds.change { $0 += 300_000 }
        sut.mutantRunsStarted()
        // A worker finishes a mutant, 239.8 s in. The other is still on its first, so the first estimate counts down:
        // 600 - 239.8 s.
        milliseconds.change { $0 += 239_800 }
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        XCTAssertTrue(lastDraw().hasSuffix("ETC: 7 min"), lastDraw())
        // The other finishes too, 240 s in: 120 s a mutant, and 8 left.
        milliseconds.change { $0 += 200 }
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        XCTAssertTrue(lastDraw().hasSuffix("ETC: 16 min"), lastDraw())
        // One more, 60 s later: 100 s a mutant, and 7 left.
        milliseconds.change { $0 += 60_000 }
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        XCTAssertTrue(lastDraw().hasSuffix("ETC: 12 min"), lastDraw())
    }

    // Each redraw moves up over the bar's two lines and erases each, so a shorter line leaves nothing of the longer one
    // it replaces. It erased only the top line, after a stray escape character.
    func test_theProgressBar_erasesEachOfItsLinesBeforeRedrawing() throws {
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()])

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 1)
        )

        let draw = printer.linesPassed.last ?? ""
        let upAndErase = "\u{1B}[1A\u{1B}[2K"
        XCTAssertTrue(draw.hasPrefix(upAndErase + upAndErase + "Inserting"), draw.debugDescription)
    }

    // Each of the bar's lines fits in an 80-column terminal, all through a run of more than a day. A line that wraps
    // takes another row, which a redraw doesn't move up over, so it's left behind on screen. The second line was up to
    // 95 columns wide.
    func test_theProgressBar_fitsIn80Columns() {
        let milliseconds = Locked<UInt64>(1_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: milliseconds.value * 1_000_000) }
        sut.resumePlanned(.make(reused: 0, toTest: 2_000, retestedBecause: [.notRecorded: 2_000]))

        // 2,000 mutants, 46 s each, on one worker: "ETC: 25 h 34 min" at first.
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 46, remainingMutationPointsCount: 2_000)
        )
        sut.mutantRunsStarted()
        for _ in 0 ..< 2_000 {
            milliseconds.change { $0 += 46_000 }
            sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        }

        let lines = printer.linesPassed.filter { $0.contains("ETC:") }.flatMap { $0.split(separator: "\n") }
        let widths = lines.map {
            $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression).count
        }
        XCTAssertEqual(lines.count, 2 * 2_001) // every draw, from 0 to all 2,000
        let widest = widths.max() ?? 0
        XCTAssertTrue(widest <= 80, "\(widest) columns")
    }

    // A log file or a pipe gets a line once the baseline passes and one as each mutant finishes, in place of the bar,
    // whose redraws move the cursor: when, how many are tested and the time left, and from the second on, what they
    // came to and the mutant.
    func test_withoutATerminal_eachMutantGetsALine_inPlaceOfTheProgressBar() throws {
        current.standardOutIsATerminal = false
        let seconds = Locked<UInt64>(0)
        let start = current.now()
        // 7 h 16 min 10 s on, so the times of day pad 0, 1 and 9 with a 0, but not 10.
        current.now = { start.addingTimeInterval(TimeInterval(seconds.value) + 26_170) }
        current.instant = { DispatchTime(uptimeNanoseconds: (1 + seconds.value) * 1_000_000_000) }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try makeSchemataMapping() })
        let printedBefore = printer.linesPassed.count
        let killed = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: .make(filePath: "/tmp/project/Module.swift", position: .init(utf8Offset: 40, line: 4, column: 7)),
            snapshot: .make(description: "changed == to !=")
        )
        let survived = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .passed,
            point: .make(filePath: "/tmp/project/View.swift", position: .init(utf8Offset: 90, line: 5, column: 28)),
            snapshot: .make(description: "removed line")
        )

        // 3 mutants, 600 s each, on one worker.
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 3)
        )
        sut.mutantRunsStarted()
        // A minute each. As in a run, each mutant's result comes before its log.
        for mutant in [killed, survived, killed] {
            seconds.change { $0 += 60 }
            sut.newMutationTestOutcomeAvailable(mutation: mutant)
            sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: mutant.point))
        }

        let printed = Array(printer.linesPassed.dropFirst(printedBefore))
        XCTAssertTrue(printed.first?.hasPrefix("📊 Determined baseline for mutation testing."), "\(printed)")
        XCTAssertEqual(Array(printed.dropFirst()), [
            "[09:58:10] 0 of 3 (0%) | 30 min left",
            "[09:59:10] 1 of 3 (33%) | 1 killed | 2 min left | killed at Module.swift:4:7 (changed == to !=)",
            "[10:00:10] 2 of 3 (66%) | 1 killed, 1 survived | 1 min left | survived at View.swift:5:28 (removed line)",
            "[10:01:10] 3 of 3 (100%) | 2 killed, 1 survived | 0 min left | "
                + "killed at Module.swift:4:7 (changed == to !=)",
        ])
    }

    // Each count is of the mutants this session tests, as the bar's is: a resumed run's kept results are sent before
    // the baseline's log, and get no line.
    func test_withoutATerminal_aResumesKeptResults_getNoLine_andArentCounted() {
        current.standardOutIsATerminal = false
        sut.resumePlanned(.make(reused: 1, toTest: 2, retestedBecause: [.notRecorded: 2]))
        var printedBefore = printer.linesPassed.count

        sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: .passed))
        XCTAssertEqual(printer.linesPassed.count, printedBefore)

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2)
        )
        printedBefore = printer.linesPassed.count
        sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: .failed))
        let line = printer.linesPassed.last ?? ""
        XCTAssertTrue(line.hasPrefix("[02:42:00] 1 of 2 (50%) | 1 killed | "), line)
        XCTAssertEqual(printer.linesPassed.count, printedBefore + 1)
    }

    // What the mutants came to so far, in a fixed order, leaving out what none came to. A crash is a kill, as the score
    // counts it.
    func test_withoutATerminal_theLinesCountWhatTheMutantsCameTo() {
        current.standardOutIsATerminal = false
        sut.resumePlanned(.make(reused: 0, toTest: 5, retestedBecause: [.notRecorded: 5]))
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 5)
        )
        let point = MutationPoint.make(filePath: "/tmp/project/Module.swift", position: 3)

        for outcome: TestSuiteOutcome in [.timeout, .buildError, .buildError, .passed, .runtimeError] {
            sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: outcome, point: point))
        }

        let lines = printer.linesPassed.suffix(5).map { $0.components(separatedBy: " | ") }
        XCTAssertEqual(lines.map { $0[1] }, [
            "1 timed out",
            "1 timed out, 1 build error",
            "1 timed out, 2 build errors",
            "1 survived, 1 timed out, 2 build errors",
            "1 killed, 1 survived, 1 timed out, 2 build errors",
        ])
        XCTAssertEqual(lines.map { $0.last ?? "" }, [
            "timed out at Module.swift:3:3",
            "build error at Module.swift:3:3",
            "build error at Module.swift:3:3",
            "survived at Module.swift:3:3",
            "killed at Module.swift:3:3",
        ])
    }

    // A burst of finished mutants redraws the bar once: it's drawn at most every tenth of a second, by the injected
    // clock, so the time between draws can be tested.
    func test_theProgressBar_isRedrawnAtMostEveryTenthOfASecond() throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 5).map { _ in try makeSchemataMapping() })
        var draws: [Int] = []
        func drawn() -> Int { printer.linesPassed.filter { $0.contains("Percentage complete:") }.count }

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 5)
        )
        draws.append(drawn())
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        draws.append(drawn())
        nanoseconds.change { $0 += 150_000_000 }
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        draws.append(drawn())

        XCTAssertEqual(draws, [1, 1, 2])
    }

    // The bar is drawn once the baseline passes, with no mutant tested yet, and again as each mutant finishes, so it
    // reaches 100% with the last one. It counted from 1, which put it one mutant ahead, never drew the last mutant,
    // and never showed the first estimate, which only a bar at 0 shows.
    func test_theProgressBar_countsTheMutantsTested_fromNoneToAll() throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = {
            nanoseconds.change { time in
                time += 200_000_000
                return DispatchTime(uptimeNanoseconds: time)
            }
        }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try makeSchemataMapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 3)
        )
        for _ in 0 ..< 3 {
            sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        }

        let draws = printer.linesPassed.filter { $0.contains("Percentage complete:") }
        XCTAssertEqual(draws.map(percent), ["0%", "33%", "66%", "100%"])
        // Three mutants, 600 s each, on one worker.
        XCTAssertTrue(draws.first?.contains("ETC: 30 "), draws.first ?? "no draw")
    }

    // The progress bar's printer redraws it by moving the cursor up over its two lines, which would overwrite the
    // warning's last two rows. The empty lines take the redraw instead. After the bar's last redraw they aren't needed.
    func test_resultsFileUnavailable_whileTheProgressBarIsStillToRedraw_leavesItTwoEmptyLines() throws {
        let reason = "can't write to /logs/results.jsonl: No space left on device"
        let warning = "⚠️ SwiftMutator can't save each mutant's result as it goes: "
            + "\(reason). The report at the end doesn't depend on it."
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping(), makeSchemataMapping()])
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 50, remainingMutationPointsCount: 2)
        )

        var printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning, "", ""])

        // With one mutant left, the bar still has its last redraw to come.
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning, "", ""])

        // The second mutant's log redraws the bar for the last time.
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning])
    }
}
