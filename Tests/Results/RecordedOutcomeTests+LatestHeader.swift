@testable import muterCore
import XCTest

extension RecordedOutcomeTests {
    // Each session's mutants are tested in the project as it was then, but reported where it is now.
    func test_pathsCoverageAndNewVersion_comeFromTheLatestHeader() throws {
        let jobs = fixtureJobs()
        let uncovered = ["/moved_mutated/Sources/Untested.swift"]

        let rebuilt = try rebuild(
            ResultsHeader.make(
                projectPath: "/project",
                mutatedProjectPath: "/project_mutated",
                coverage: CoverageSummary(percent: 50, filesWithoutCoverage: []),
                newVersion: ""
            ),
            mutantResult(jobs[0].schema, jobs[0].key),
            ResultsEnd.make(testDurationSeconds: 100.5, recorded: 1),
            ResultsHeader.make(
                session: 2,
                startedAt: ResultsHeader.fixedStart + 3_600,
                projectPath: "/moved",
                mutatedProjectPath: "/moved_mutated",
                coverage: CoverageSummary(percent: 78, filesWithoutCoverage: uncovered),
                newVersion: "9.9.9",
                configuration: MuterConfiguration(
                    executable: "/usr/bin/swift", arguments: ["test"], suspectTestFilePercent: 40
                )
            ),
            mutantResult(jobs[4].schema, jobs[4].key, outcome: .passed, session: 2),
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 1)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/moved_mutated/Sources/A/Util.swift", outcome: .failed, project: "/moved"),
            mutation(jobs[4].schema, at: "/moved_mutated/Sources/Zeta.swift", outcome: .passed, project: "/moved"),
        ])
        XCTAssertEqual(rebuilt.mutations.map(\.originalProjectPath), [
            "/moved/Sources/A/Util.swift",
            "/moved/Sources/Zeta.swift",
        ])
        XCTAssertEqual(rebuilt.coverage, .make(percent: 78, filesWithoutCoverage: uncovered))
        XCTAssertEqual(rebuilt.newVersion, "9.9.9")
        XCTAssertEqual(rebuilt.testDuration, 120.75)
        XCTAssertEqual(rebuilt.suspectTestThresholds, SuspectTestThresholds(filePercent: 40, minimumFiles: 10))
    }

    // A resumed session discovers them again, so its header's replace the last session's, as every scope field does;
    // and none of them is a mutation, whose counts the reports show.
    func test_theMutantsOfCodeNoTestRan_comeFromTheLatestHeader_andAreNoMutation() throws {
        let jobs = fixtureJobs()
        let uncovered = { (line: Int) in
            UncoveredMutant(
                key: MutantKey(
                    path: "Sources/New.swift",
                    mutationOperatorId: .ror,
                    line: line,
                    column: 9,
                    occurrence: 0
                ),
                snapshot: .make(before: "<", after: ">")
            )
        }
        var first = ResultsHeader.make()
        first.mutantsNotCovered = [uncovered(4), uncovered(8)]
        var second = ResultsHeader.make(session: 2, startedAt: ResultsHeader.fixedStart + 3_600)
        second.mutantsNotCovered = [uncovered(8)]

        let rebuilt = try rebuild(
            first,
            mutantResult(jobs[0].schema, jobs[0].key),
            ResultsEnd.make(testDurationSeconds: 100.5, recorded: 1),
            second,
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 0)
        )

        XCTAssertEqual(rebuilt.uncoveredMutants, [uncovered(8)])
        XCTAssertEqual(rebuilt.mutations.count, 1)
        XCTAssertEqual(try rebuild(first, ResultsEnd.make(recorded: 0)).uncoveredMutants, [uncovered(4), uncovered(8)])
        XCTAssertEqual(try rebuild(ResultsHeader.make(), ResultsEnd.make(recorded: 0)).uncoveredMutants, [])
        // With coverage on, a header without them didn't record them, as an older SwiftMutator's: they aren't known,
        // and no baseline file is made of the results.
        let older = try rebuild(ResultsHeader.make(skipCoverage: false), ResultsEnd.make(recorded: 0))
        XCTAssertNil(older.uncoveredMutants)
        var whole = MutationTestOutcome()
        XCTAssertNil(whole.whyNoBaselineFile)
        whole.uncoveredMutants = older.uncoveredMutants
        XCTAssertEqual(whole.whyNoBaselineFile, MutationTestOutcome.uncoveredMutantsUnknown)
        var none = ResultsHeader.make(skipCoverage: false)
        none.mutantsNotCovered = []
        XCTAssertEqual(try rebuild(none, ResultsEnd.make(recorded: 0)).uncoveredMutants, [])
    }

    // A resumed session retires the results it doesn't stand by, and records again those it tests again.
    func test_aRetiredKey_isLeftOutOfTheReport() throws {
        let jobs = fixtureJobs()

        let rebuilt = try rebuild(
            ResultsHeader.make(),
            mutantResult(jobs[0].schema, jobs[0].key),
            mutantResult(jobs[1].schema, jobs[1].key),
            mutantResult(jobs[3].schema, jobs[3].key),
            ResultsEnd.make(reason: .interrupted, testDurationSeconds: 100.5, recorded: 3),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                startedAt: ResultsHeader.fixedStart + 3_600
            ),
            ResultsRetired(session: 2, keys: [jobs[1].key, jobs[3].key]),
            mutantResult(jobs[3].schema, jobs[3].key, outcome: .passed, session: 2),
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 1)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/project_mutated/Sources/A/Util.swift", outcome: .failed),
            mutation(jobs[3].schema, at: "/project_mutated/Sources/Zeta.swift", outcome: .passed),
        ])
        XCTAssertEqual(rebuilt.testDuration, 120.75)
    }

    // A stopped run's list may not name every test that failed, nor may a list that names fewer than were counted.
    func test_eachMutationsKillingTests_comeFromItsRecord() throws {
        let jobs = fixtureJobs()
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let total = FailedTestLine.FailedTest(name: "total()", location: "TotalTests.swift:8:5")

        let rebuilt = try rebuild(
            ResultsHeader.make(),
            mutantResult(jobs[2].schema, jobs[2].key, killedBy: [], failedTestCount: 0),
            mutantResult(jobs[1].schema, jobs[1].key, outcome: .passed),
            mutantResult(
                jobs[0].schema,
                jobs[0].key,
                killedBy: [sum, total],
                failedTestCount: 3,
                endedBy: .stoppedAtFailedTest
            )
        )

        XCTAssertEqual(rebuilt.mutations.map(\.killingTests), [
            MutationTestOutcome.KillingTests(tests: [sum, total], count: 3, isComplete: false),
            nil,
            .noneNamed,
        ])
    }

    func test_aRunWithoutCoverage_reportsNone() throws {
        let jobs = fixtureJobs()

        let rebuilt = try rebuild(
            ResultsHeader.make(coverage: nil, skipCoverage: false),
            mutantResult(jobs[0].schema, jobs[0].key)
        )

        XCTAssertEqual(rebuilt.mutations.map(label), ["/project_mutated/Sources/A/Util.swift:3"])
        XCTAssertEqual(rebuilt.coverage, .null)
        XCTAssertFalse(rebuilt.coverageSkipped)
        XCTAssertNil(MuterTestReport(from: rebuilt).projectCodeCoverage)
        let report = PlainTextReporter().report(from: rebuilt)
        XCTAssertTrue(report.contains("\nSwiftMutator could not gather coverage data from your project\n"), report)
        XCTAssertFalse(report.contains("Coverage skipped"), report)
    }

    // `--skip-coverage` leaves a run without coverage, as failing to gather it does, but neither its report nor the one
    // made from its file says SwiftMutator failed.
    func test_aRunThatSkippedCoverage_saysSo_asDoesTheReportFromItsFile() async throws {
        state.runOptions = .make(skipCoverage: true)
        state.projectCoverage = .null
        // The baseline, then the five mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .passed, .passed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertTrue(runOutcome.coverageSkipped)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.skipCoverage), [true])
        let report = PlainTextReporter().report(from: runOutcome)
        XCTAssertTrue(report.contains("\nCoverage skipped (--skip-coverage)\n"), report)
        XCTAssertFalse(report.contains("could not gather coverage data"), report)
        try assertTheResultsFileRebuilds(runOutcome)
    }

    // Discovery sorts the absolute paths, so a file outside the mutated project keeps its place among them: here
    // after them, although its path, written as it is, sorts before theirs, written relative to the project.
    func test_aPathOutsideTheMutatedProject_staysAsItWas() throws {
        state.mutationMapping = try (state.mutationMapping + [
            makeMapping("/var/generated/Version.swift", lines: [4]),
        ]).mergeByFilePath()
        let jobs = fixtureJobs()
        let outside = try XCTUnwrap(jobs.last)
        XCTAssertEqual(outside.key.path, "/var/generated/Version.swift")

        let rebuilt = try rebuild(
            ResultsHeader.make(mutantsDiscovered: 6, mutantsToTest: 6),
            mutantResult(outside.schema, outside.key),
            mutantResult(jobs[0].schema, jobs[0].key)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/project_mutated/Sources/A/Util.swift", outcome: .failed),
            mutation(outside.schema, at: "/var/generated/Version.swift", outcome: .failed),
        ])
    }
}
