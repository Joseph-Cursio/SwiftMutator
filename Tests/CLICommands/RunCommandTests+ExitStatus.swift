import ArgumentParser
@testable import muterCore
import XCTest

extension RunCommandTests {
    // Refusing is an expected outcome, whose message says what to do; it isn't a bug to report.
    func test_aRefusal_isShownWithoutTheBugReportBanner() {
        let refused = ResumeRefused(
            path: "/logs/results.jsonl",
            reasons: [.inUse(holder: nil, lastProcess: 81_234, lastHost: "studio.local")],
            beforeTheCopy: true
        )

        XCTAssertEqual(Run.message(showing: refused), "\(refused)")
        let inUse = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81_234)
        XCTAssertEqual(Run.message(showing: inUse), "\(inUse)")
        let plan = TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .copyMissing(path: "/code/x_mutated"))
        XCTAssertEqual(Run.message(showing: plan), "\(plan)")
        let mutant = MutantRefused(
            reference: MutantReference(path: "Bar.swift", line: 12),
            reason: .notFound(nearby: [], files: 0)
        )
        XCTAssertEqual(Run.message(showing: mutant), "\(mutant)")
        let cannotLock = Run.message(showing: MutatedProjectLockError.cannotLock(path: "/x.lock", errno: EACCES))
        XCTAssertTrue(cannotLock.contains("SwiftMutator has encountered an error"), cannotLock)
        let other = Run.message(showing: MuterError.noSourceFilesDiscovered)
        XCTAssertTrue(other.contains("SwiftMutator has encountered an error"), other)
        XCTAssertTrue(other.contains("\(MuterError.noSourceFilesDiscovered)"), other)
        XCTAssertTrue(other.contains("please open an issue"), other)
        XCTAssertTrue(other.contains("open an issue at\nhttps://github.com/Joseph-Cursio/SwiftMutator/issues"), other)
        XCTAssertFalse(other.contains("muter-mutation-testing"), other)
    }

    // A script can tell a refused resume or reuse, and a run another holds a lock against, from an error, and from
    // each other: after the first, a new run starts, and after the second, waiting for the other run lets it through.
    // A low score, a failed baseline and an abort each have one too.
    func test_eachOutcome_exitsWithItsOwnStatus() {
        XCTAssertEqual(ExitCode.scoreBelowThreshold.rawValue, 2)
        XCTAssertEqual(ExitCode.baselineFailed.rawValue, 3)
        XCTAssertEqual(ExitCode.abortedMidRun.rawValue, 4)
        XCTAssertEqual(ExitCode.resumeRefused.rawValue, 5)
        XCTAssertEqual(ExitCode.anotherRunHoldsTheLock.rawValue, 6)
        XCTAssertEqual(ExitCode.testPlanRefused.rawValue, 7)
        XCTAssertEqual(ExitCode.baselineRefused.rawValue, 8)
        XCTAssertEqual(ExitCode.stoppedOnAnError.rawValue, -1)
        let baseline = BaselineRefused(path: "muter.baseline.yml", reasons: ["It isn't UTF-8."])
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: baseline), .baselineRefused)
        for refused in Self.refusedResumes {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: refused), .resumeRefused, "\(refused)")
        }
        let lockedFile = ResumeRefused(
            path: "/logs/results.jsonl",
            reasons: [.inUse(holder: nil, lastProcess: 81_234, lastHost: "studio.local")],
            beforeTheCopy: true
        )
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: lockedFile), .anotherRunHoldsTheLock)
        let lockedCopy = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81_234)
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: lockedCopy), .anotherRunHoldsTheLock)
        for refused in Self.refusedTestPlans {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: refused), .testPlanRefused, "\(refused)")
        }
        for error in Self.errorsThatStopARun {
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .stoppedOnAnError, "\(error)")
        }
        let nothing = NothingToMutate(reason: .noSwiftFileChanged, selection: .make())
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: nothing))
        let empty = EmptyShard(shard: Shard(index: 3, count: 4), mutantsInAllShards: 2)
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: empty))
        for (reason, status) in Self.everyAbortReason {
            XCTAssertEqual(
                ExitCode.exitStatus(afterRunFailedWith: MuterError.mutationTestingAborted(reason: reason)),
                status,
                "\(reason)"
            )
        }
    }

    /// Resumes and reuses refused for reasons a new run gets past: changed settings or files, a report that would
    /// replace the results file, or a lock held alongside another reason.
    static var refusedResumes: [ResumeRefused] {
        let difference = ResumeCheck.Difference(name: "mutationTestTimeout", was: "120", isNow: "60")
        let changes = [ProjectTree.FileChange(path: "notes.txt", kind: .added)]
        return [
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.configurationChanged(difference), .filesChanged(changes)],
                beforeTheCopy: true
            ),
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.configurationChanged(difference)],
                beforeTheCopy: true,
                isReuse: true
            ),
            ResumeRefused(path: "/logs/results.jsonl", reasons: [.filesChanged(changes)], beforeTheCopy: false),
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.reportWouldReplaceTheResultsFile("/logs/results.jsonl")],
                beforeTheCopy: true
            ),
            // Held, but refused for another reason too: it won't resume once the lock is free either.
            ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.inUse(holder: nil, lastProcess: 81_234, lastHost: "studio.local"), .filesChanged(changes)],
                beforeTheCopy: true
            ),
        ]
    }

    /// Test plans refused for being of a newer format, or for a missing copy.
    static var refusedTestPlans: [TestPlanRefused] {
        [
            TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .newerFormat(found: 3)),
            TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .copyMissing(path: "/code/x_mutated")),
        ]
    }

    /// Errors that stop a run without a status of their own.
    static var errorsThatStopARun: [Error] {
        [
            MutatedProjectLockError.cannotLock(path: "/x.lock", errno: EACCES),
            ResultsFileError.newerFormat(path: "/logs/results.jsonl", version: 3),
            ChangeSelectionError.unknownRef("origin/main"),
            MuterError.noSourceFilesDiscovered,
            MuterError.configurationParsingError(reason: "failUnder must be a number from 0 to 100, not 101"),
        ]
    }

    // Each sample abort reason is of the kind it stands for, so every kind, and so every case, has a sample.
    func test_everyAbortReason_hasOneOfEachKind() {
        let kinds = Self.everyAbortReason.map(\.0.kind)
        XCTAssertEqual(kinds, MutationTestingAbortReason.Kind.allCases)
    }

    // The verdict decides the status of a run that ended without failing or a signal; a failure's status wins.
    func test_aRunsVerdictOnItsScore_decidesItsStatus() {
        let below = ScoreGate(failUnder: 80, judging: .make([.failed, .passed]))
        let meets = ScoreGate(failUnder: 50, judging: .make([.failed, .passed]))
        let oneMutant = ScoreGate(failUnder: 80, judging: .make([.passed], mutant: "Foo.swift:3:9"))
        let ended = { (gate: ScoreGate?) in
            Interruptions.Ended<RunChecks>(result: .success(RunChecks(scoreGate: gate)), signal: nil)
        }

        XCTAssertEqual(ended(below).exitStatus, .scoreBelowThreshold)
        XCTAssertNil(ended(meets).exitStatus)
        XCTAssertNil(ended(oneMutant).exitStatus)
        XCTAssertNil(ended(nil).exitStatus)
        let aborted = Interruptions.Ended<RunChecks>(
            result: .failure(MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)),
            signal: nil
        )
        XCTAssertEqual(aborted.exitStatus, .abortedMidRun)
        let nothing = Interruptions.Ended<RunChecks>(
            result: .failure(NothingToMutate(reason: .noSwiftFileChanged, selection: .make())),
            signal: nil
        )
        XCTAssertNil(nothing.exitStatus)
    }

    // On each command that tests mutants, in place of failUnder, and on `report`; never `mutate-without-running`,
    // which tests nothing.
    func test_failUnder_reachesTheRunOptions_ofEachCommandThatTests_andTheHelp() throws {
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--fail-under", "80"]) as? Run)
        XCTAssertEqual(run.runOptions.failUnder, 80)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--fail-under", "72.5", "plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.failUnder, 72.5)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.failUnder)
        let report = try XCTUnwrap(MuterCommand.parseAsRoot(["report", "r.jsonl", "--fail-under", "0"]) as? Report)
        XCTAssertEqual(report.reportOptions.failUnder, 0)
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["mutate-without-running", "--fail-under", "80"]))
        for help in [Run.helpMessage(columns: 200), RunWithoutMutating.helpMessage(columns: 200)]
            + [Report.helpMessage(columns: 200)] {
            XCTAssertTrue(help.contains("\n  --fail-under <percent>"), help)
        }
        XCTAssertFalse(MutateWithoutRunning.helpMessage(columns: 200).contains("--fail-under"))
    }

    func test_aFailUnderThatIsntAPercent_isAUsageError() {
        let refused = ["-1", "100.1", "101", "nan", "inf", "eighty", "1e2", "0x50", "+80", "80.", ".5", "8 0"]
            + ["8_0", "1:20", "0.0000001", "33.3333333"]
        for value in refused {
            for command in [["run"], ["report", "r.jsonl"]] {
                assertUsageError(
                    command + ["--fail-under=\(value)"],
                    "The value '\(value)' is invalid for '--fail-under <percent>': give a percent from 0 to 100, with "
                        + "at most 6 decimals, such as 80 or 72.5."
                )
            }
        }
        for value in ["0", "100", "72.5", "0.05", "080", "0.000001", "33.333333"] {
            XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--fail-under", value]), value)
        }
    }

    // git couldn't answer, or there is nothing to mutate: each says what happened, and neither is a bug.
    func test_sinceOutcomes_areShownWithoutTheBugReportBanner() {
        let unknown = ChangeSelectionError.unknownRef("origin/main")
        XCTAssertEqual(Run.message(showing: unknown), "\(unknown)")
        let nothing = NothingToMutate(reason: .noSwiftFileChanged, selection: .make())
        XCTAssertEqual(Run.message(showing: nothing), "\(nothing)")
    }
}
