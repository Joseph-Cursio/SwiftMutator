@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingReuseTests {
    // `swift-mutator report` of the new file alone gives the run's own report, the reused results marked.
    func test_theReportFromTheNewFile_equalsTheRunsOwn_withTheReusedResultsMarked() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 2.5)
            }
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let file = Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        let path = "/project_muter_logs/now/results.jsonl"
        let fromTheFile = try RecordedResults.read(file, path: path).mutationTestOutcome(resultsFile: path)
        XCTAssertEqual(fromTheFile, outcome)
        XCTAssertEqual(outcome.mutations.map { $0.reusedFrom != nil }, [true, false, true, false])
    }

    // What a waiver let through since a result was tested marks it, so the reports can say so; and what a force let
    // through marks every result kept.
    func test_resultsKeptDespiteAWaiverOrAForce_areMarked() async throws {
        try reuse(recorded, changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        state.resumeWaived = ["README.md"]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        var kept = try resultsFiles.records(MutantResult.self).compactMap(\.reusedFrom)
        XCTAssertEqual(kept.map(\.despiteChanges), [true, true])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.waived, ["README.md"])

        state.resumeState = try ResumeState.make(
            lines: recorded,
            file: nil,
            path: earlierPath,
            forced: ["toolchain.environment"]
        )
        state.reuseChanges = [1: ReuseChanges(from: tree, to: tree, waiving: []) { _ in nil }]
        state.resumeWaived = []
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        _ = try await sut.run(with: state)
        // The second run's file comes after the first's.
        kept = try Array(resultsFiles.records(MutantResult.self).compactMap(\.reusedFrom).dropFirst(2))
        XCTAssertEqual(kept.map(\.despiteChanges), [true, true])
    }

    // A waiver marks only the results tested before the change it let through: a session that resumed the earlier run
    // after it tested its results under the changed file already.
    func test_aWaiverMarksOnlyTheResultsOfSessionsTestedBeforeTheChange() async throws {
        let changed = ProjectTree(
            listedBy: .git,
            files: tree.files.merging(["README.md": "ffff"]) { $1 },
            excluded: [],
            treeSHA256: "f00d"
        )
        let lines: [any Encodable] = [
            ResultsHeader.make(project: tree, logDirectory: "/project_muter_logs/earlier"),
            record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
            ResultsEnd.make(reason: .interrupted, recorded: 1),
            ResultsHeader.make(
                formatVersion: 2,
                session: 2,
                project: changed,
                logDirectory: "/project_muter_logs/later"
            ),
            MutantResult.make(
                session: 2,
                path: "Sources/Sum.swift",
                line: 3,
                column: 5,
                utf8Offset: 30,
                switchID: "Sum_RelationalOperatorReplacement_3_5_30",
                outcome: .failed,
                killedBy: [sumTest],
                fileSHA256: "5a1c"
            ),
            ResultsEnd.make(session: 2, recorded: 1),
        ]
        state.resumeState = try ResumeState.make(lines: lines, file: nil, path: earlierPath)
        state.reuseChanges = [
            1: ReuseChanges(from: tree, to: changed, waiving: ["README.md"]) { _ in nil },
            2: ReuseChanges(from: changed, to: changed, waiving: ["README.md"]) { _ in nil },
        ]
        state.resumeWaived = ["README.md"]
        // So the kill's log is copied too.
        state.muterConfiguration = keepingAllLogs
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed]

        _ = try await sut.run(with: state)

        let kept = try resultsFiles.records(MutantResult.self).filter { $0.reusedFrom != nil }
        XCTAssertEqual(kept.map(\.path), ["Sources/Product.swift", "Sources/Sum.swift"])
        XCTAssertEqual(kept.map(\.reusedFrom?.despiteChanges), [true, false])
        XCTAssertEqual(
            fileManager.copyPaths.map(\.source).filter { $0.hasPrefix("/project_muter_logs/later") },
            ["/project_muter_logs/later/RelationalOperatorReplacement @ Sum.swift-3-5.log"],
            "each log from its own session's folder"
        )
    }
}
