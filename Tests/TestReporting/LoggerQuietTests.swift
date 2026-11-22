@testable import muterCore
import XCTest

/// What the logger leaves out with --quiet: the banner, progress and notices. Warnings, errors and the summary stay.
final class LoggerQuietTests: MuterTestCase {
    private let sut = Logger()

    override func setUp() {
        super.setUp()
        sut.quiet = true
    }

    func test_theBanner_andTheUpdateCheck_printNothing() {
        sut.launched()
        sut.updateCheckStarted()
        sut.updateCheckFinished(newVersion: "99.0.0")
        sut.updateCheckFinished(newVersion: nil)

        XCTAssertEqual(printer.linesPassed, [])
    }

    // The bar is never made, but the mutants are still counted. A warning then needs no room for a redraw.
    func test_onATerminal_noProgressBarIsDrawn_theMutantsAreStillCounted_andAWarningGetsNoEmptyLines() throws {
        let reason = "can't write to /logs/results.jsonl: No space left on device"
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try mapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 3)
        )
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        sut.resultsFileUnavailable(reason: reason)

        XCTAssertEqual(sut.numberOfMutationPoints, 3)
        XCTAssertEqual(printer.linesPassed, [
            "⚠️ SwiftMutator can't save each mutant's result as it goes: \(reason). "
                + "The report at the end doesn't depend on it.",
        ])
    }

    func test_withoutATerminal_noMutantGetsALine() throws {
        current.standardOutIsATerminal = false
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 2).map { _ in try mapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2)
        )
        sut.mutantRunsStarted()
        sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: .failed))
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))

        XCTAssertEqual(sut.numberOfMutationPoints, 2)
        XCTAssertEqual(printer.linesPassed, [])
    }

    // A resumed run's total is still set, though its ♻️ line isn't printed.
    func test_aResume_stillSetsTheTotal() {
        sut.resumePlanned(.make(reused: 3, toTest: 4, retestedBecause: [.notRecorded: 4]))

        XCTAssertEqual(sut.numberOfMutationPoints, 4)
        XCTAssertEqual(printer.linesPassed, [])
    }

    // Off a terminal, the line that says the run is still testing is then all a log gets while the mutants run, and
    // it keeps a CI job that stops a silent run going. It comes on the heartbeat's interval, whatever else prints.
    func test_withoutATerminal_theHeartbeatStillPrints_eachTimeItIsDue() {
        current.standardOutIsATerminal = false
        let heartbeat = Heartbeat()
        let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        heartbeat.begin(workers: 1, at: start)
        heartbeat.started("Rules.swift:42:17", on: 0, at: start)
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2)
        )

        for minute in 1 ... 2 {
            let time = DispatchTime(uptimeNanoseconds: start.uptimeNanoseconds + UInt64(minute) * 60_000_000_000)
            let still = heartbeat.due(at: time)
            XCTAssertNotNil(still, "minute \(minute)")
            still.map(sut.stillTesting)
        }

        XCTAssertEqual(printer.linesPassed, [
            "[02:42:00] still testing | Rules.swift:42:17 for 60 s",
            "[02:42:00] still testing | Rules.swift:42:17 for 120 s",
        ])
    }

    func test_onATerminal_theHeartbeatPrintsNothing() {
        sut.stillTesting(StillTesting(runs: [.init(worker: 0, place: "Rules.swift:42:17", seconds: 75)], workers: 1))

        XCTAssertEqual(printer.linesPassed, [])
    }

    // The 🎲 line is the console's only record of a seed SwiftMutator chose, so it stays; the count goes.
    func test_aChosenSeed_isStillSaid() throws {
        let selection = SampleSelection(size: 500, seed: 7, mutantsSampledFrom: 2_497, mutantsSampled: 500)

        try sut.mutationsDiscoveryFinished(mutations: [mapping()], sample: (selection, true))

        XCTAssertEqual(printer.linesPassed, [
            "🎲 SwiftMutator chose the sample's seed, 7: --seed 7 takes the same sample again.",
        ])
    }

    // The runs left are warnings, which stay; the runs removed, and the line saying where, go.
    func test_logFoldersPruned_keepsOnlyTheRunsLeft() {
        var pruning = LogFolderPruning(root: "/p_muter_logs", keeping: 2)
        pruning.removed = [.init(folders: ["Oct 9, 2026 at 9:00 AM"], shard: nil)]
        pruning.left = [.init(folders: ["Oct 1, 2026 at 8:12 AM"], reason: .inUse)]

        sut.logFoldersPruned(pruning)
        pruning.left = []
        sut.logFoldersPruned(pruning)

        XCTAssertEqual(printer.linesPassed, ["⚠️ Left Oct 1, 2026 at 8:12 AM: another SwiftMutator run is using it."])
    }

    // The phases turned off are a notice, which goes; what may still run SwiftLint is a warning, which stays.
    func test_swiftLintPhasesTurnedOff_keepsOnlyItsWarnings() {
        let turnedOff = [SwiftLintPhases.Phase(project: "App.xcodeproj", name: "Run SwiftLint", targets: ["App"])]

        sut.swiftLintPhasesTurnedOff(SwiftLintPhases(turnedOff: turnedOff))
        sut.swiftLintPhasesTurnedOff(SwiftLintPhases(turnedOff: turnedOff, unreadProjects: ["Old.xcodeproj"]))

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ Couldn't read or write Old.xcodeproj in the copy, which names SwiftLint, so its build phases may still "
                + "run it.",
        ])
    }

    // Each kind of line the flag leaves out, against a warning and an error, which it doesn't.
    func test_progressAndNotices_go_warningsAndErrors_stay() {
        sut.sourceFileDiscoveryStarted()
        sut.projectCopyStarted()
        sut.projectCoverageDiscoveryStarted()
        sut.mutationTestingStarted()
        sut.workersShareUserDefaults()
        sut.macWorkersShareUserDefaults()
        sut.resultsFileCreated(atPath: "/logs/results.jsonl")
        sut.stopAtFirstFailureTurnedOff(reason: "the tests run in parallel")
        sut.projectCoverageDiscoveryFinished(failureReason: "no profile data")

        XCTAssertEqual(printer.linesPassed.count, 2, "\(printer.linesPassed)")
        XCTAssertEqual(printer.linesPassed.first?.hasPrefix("⚠️ stopAtFirstFailure is off"), true)
        XCTAssertEqual(printer.linesPassed.last?.hasPrefix("❌ Gathering coverage failed"), true)
    }

    /// A file's mapping with one mutant.
    private func mapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            (
                source: "func bar() { }",
                schemata: [.make(filePath: "/tmp/project/file.swift", position: .firstPosition)]
            ),
            filePath: "/some/path"
        )
    }
}
