@testable import muterCore
// As in PlainTextReporterTests: XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import TestingExtensions
import XCTest

/// Each mutant's path, key and duration, where the results came from, and `summary.json`.
final class RunDetailsReportTests: MuterTestCase {
    private let project = URL(fileURLWithPath: "/work/Foo")
    private let copy = URL(fileURLWithPath: "/work/Foo_mutated")
    private let run = RunDetails(of: [("/logs/results.jsonl", [.make(workers: 4, timeoutSeconds: 24)])])

    override func setUp() {
        super.setUp()
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    private func mutant(
        _ outcome: TestSuiteOutcome,
        _ path: String,
        line: Int,
        seconds: Double? = 2.4,
        killingTests: MutationTestOutcome.KillingTests? = nil
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: .ror,
                filePath: copy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: 9)
            ),
            snapshot: .make(before: "==", after: "!=", description: "changed == to !="),
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: copy,
            killingTests: killingTests,
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: 9, occurrence: 0),
            durationSeconds: seconds
        )
    }

    private func outcome(_ mutations: [MutationTestOutcome.Mutation]) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            testDuration: 61.25,
            projectPath: project.path,
            mutatedProjectPath: copy.path,
            run: run
        )
    }

    private func json(of outcome: MutationTestOutcome) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
    }

    // A script can find each mutant by its path in the project, test it again by its key, and see how long it took,
    // where `mutationPoint` gives its path in the mutated copy.
    func test_theJSON_givesEachMutantsPathKeyAndDuration_andEachFilesPath() throws {
        let report = try json(of: outcome([
            mutant(.passed, "Sources/Lint/Rules.swift", line: 12, seconds: 6.9),
            mutant(.failed, "Sources/Rules.swift", line: 3),
        ]))

        let fileReports = try XCTUnwrap(report["fileReports"] as? [[String: Any]])
        XCTAssertEqual(fileReports.map { $0["path"] as? String }, ["Sources/Lint/Rules.swift", "Sources/Rules.swift"])
        XCTAssertEqual(fileReports.map { $0["fileName"] as? String }, ["Rules.swift", "Rules.swift"])
        let survivor = try XCTUnwrap((fileReports.first?["appliedOperators"] as? [[String: Any]])?.first)
        XCTAssertEqual(survivor["path"] as? String, "Sources/Lint/Rules.swift")
        XCTAssertEqual(survivor["key"] as? String, "Sources/Lint/Rules.swift:12:9 RelationalOperatorReplacement")
        XCTAssertEqual(survivor["durationSeconds"] as? Double, 6.9)
        XCTAssertEqual(
            (survivor["mutationPoint"] as? [String: Any])?["filePath"] as? String,
            "/work/Foo_mutated/Sources/Lint/Rules.swift"
        )
    }

    // And they read back, as does a report written before them, whose file has its name alone.
    func test_theNewKeys_readBack_andAReportWithoutThemStillReads() throws {
        let outcome = outcome([mutant(.passed, "Sources/Rules.swift", line: 12)])
        let json = Data(JsonReporter().report(from: outcome).utf8)
        let decoded = try JSONDecoder().decode(MuterTestReport.self, from: json)

        let original = MuterTestReport(from: outcome)
        XCTAssertEqual(decoded.fileReports.map(\.relativePath), ["Sources/Rules.swift"])
        XCTAssertEqual(
            decoded.fileReports.flatMap(\.appliedOperators),
            original.fileReports.flatMap(\.appliedOperators)
        )
        XCTAssertEqual(decoded.run, run)

        let older = """
        {"globalMutationScore": 0, "totalAppliedMutationOperators": 0, "numberOfKilledMutants": 0,
         "timeElapsed": "00:00:00.000",
         "fileReports": [{"fileName": "Rules.swift", "mutationScore": 0, "appliedOperators": []}]}
        """
        let read = try JSONDecoder().decode(MuterTestReport.self, from: Data(older.utf8))
        XCTAssertEqual(read.fileReports.map(\.relativePath), ["Rules.swift"])
        XCTAssertNil(read.run)
    }

    // A Duration column, in the plain and HTML reports, once some mutant's duration is known; none without.
    func test_thePlainAndHTMLReports_haveADurationColumn_whenDurationsAreKnown() {
        let timed = outcome([mutant(.passed, "Sources/Rules.swift", line: 12, seconds: 6.94)])
        let untimed = outcome([mutant(.passed, "Sources/Rules.swift", line: 12, seconds: nil)])

        let plainText = PlainTextReporter().report(from: timed)
        XCTAssertTrue(plainText.contains("Duration"), plainText)
        XCTAssertTrue(plainText.contains("   6.9 s\n"), plainText)
        XCTAssertFalse(PlainTextReporter().report(from: untimed).contains("Duration"))
        let html = HTMLReporter().report(from: timed)
        XCTAssertTrue(html.contains("<th>Duration</th>"), html)
        XCTAssertTrue(html.contains(#"<td class="right-aligned">6.9 s</td>"#), html)
        XCTAssertFalse(HTMLReporter().report(from: untimed).contains("<th>Duration</th>"))
    }

    // Where the results came from ends the plain report, and the HTML report, escaped.
    func test_thePlainAndHTMLReports_sayWhereTheResultsCameFrom() {
        let lines = [
            "Results file: /logs/results.jsonl",
            "SwiftMutator: 1.0.0, executable SHA-256 9f2c",
            "Toolchain: Apple Swift version 6.4",
            "Workers: 4; time limit per mutant: 24 s, the default",
        ]
        XCTAssertEqual(run?.lines, lines)

        let plainText = PlainTextReporter().report(from: outcome([]))
        XCTAssertTrue(plainText.hasSuffix("\n---\nRun\n---\n\n" + lines.joined(separator: "\n")), plainText)
        XCTAssertFalse(PlainTextReporter().report(from: MutationTestOutcome()).contains("\nRun\n"))

        var awkward = outcome([])
        awkward.run = RunDetails(of: [("/logs/<a & b>/results.jsonl", [.make()])])
        let html = HTMLReporter().report(from: awkward)
        XCTAssertTrue(html.contains("<p>Results file: /logs/&lt;a &amp; b&gt;/results.jsonl</p>"), html)
    }

    // A merge's files and every shard's sessions, a configured limit, none, and a toolchain that says more than a line.
    func test_theRunsLines_sayWhatTheHeadersRecord() throws {
        var provenance = Provenance.fixture
        provenance = Provenance(
            swiftMutator: .init(version: "1.4.0", executablePath: nil, executableSHA256: nil),
            toolchain: .init(
                testCommandVersion: "Apple Swift version 6.2\nTarget: arm64-apple-macosx26.0",
                testExecutableSHA256: nil,
                environment: [:]
            ),
            processIdentifier: provenance.processIdentifier,
            host: provenance.host,
            arguments: provenance.arguments
        )
        let header = ResultsHeader.make(session: 3, provenance: provenance, workers: 2, timeoutSeconds: nil)

        let merged = try XCTUnwrap(RunDetails(of: [("/a.jsonl", [header]), ("/b.jsonl", [.make()])]))
        XCTAssertEqual(merged.lines, [
            "Results files: /a.jsonl, /b.jsonl (4 sessions)",
            "SwiftMutator: 1.4.0",
            "Toolchain: Apple Swift version 6.2",
            "Workers: 2; no time limit",
        ])
    }

    // A session with nothing left to test tests no mutant, so the settings are the last ones that tested any.
    func test_aSessionThatTestedNothing_leavesTheSettingsTheResultsWereTestedWith() throws {
        let tested = ResultsHeader.make(workers: 4, timeoutSeconds: 24)
        let empty = ResultsHeader.make(session: 2, workers: 0, timeoutSeconds: nil)

        let resumed = try XCTUnwrap(RunDetails(of: [("/logs/results.jsonl", [tested, empty])]))
        XCTAssertEqual(resumed.sessions, 2)
        XCTAssertEqual(resumed.workers, 4)
        XCTAssertEqual(resumed.timeoutSeconds, 24)
        XCTAssertEqual(resumed.lines.last, "Workers: 4; time limit per mutant: 24 s, the default")

        // As a `--reuse` with nothing to test writes it: a new file, whose results another run tested.
        let reused = try XCTUnwrap(RunDetails(of: [("/logs/results.jsonl", [.make(workers: 0, timeoutSeconds: nil)])]))
        XCTAssertEqual(reused.lines.last, "Workers: none, as no mutant was left to test")
        XCTAssertNil(RunDetails(of: [("/logs/results.jsonl", [])]))
    }

    // What a script needs: how the run ended, its score and counts, how long it took, and where its results came
    // from, with sorted keys.
    func test_theSummary_holdsTheScoreCountsDurationAndRun() throws {
        let outcome = outcome([
            mutant(.failed, "Sources/Rules.swift", line: 3),
            mutant(.passed, "Sources/Rules.swift", line: 12),
            mutant(.timeout, "Sources/Rules.swift", line: 20),
        ])
        let summary = RunSummary(of: outcome, ended: .finished, report: "/out/report.html")

        XCTAssertEqual(summary.ended, .finished)
        XCTAssertNil(summary.endDetail)
        XCTAssertEqual(summary.mutationScore, 33)
        XCTAssertNil(summary.mutationScoreWithoutSuspectTests)
        XCTAssertEqual(summary.mutants, 3)
        XCTAssertEqual(summary.mutantsByOutcome, OutcomeCounts(killed: 1, survived: 1, timedOut: 1))
        XCTAssertEqual(summary.durationSeconds, 61.25)
        XCTAssertEqual(summary.report, "/out/report.html")
        XCTAssertEqual(summary.run, run)
        let text = String(decoding: summary.json, as: UTF8.self)
        XCTAssertTrue(text.contains(#""report" : "/out/report.html""#), text)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, [
            "durationSeconds", "ended", "formatVersion", "mutants", "mutantsByOutcome", "mutationScore", "report",
            "run",
        ])
        XCTAssertEqual(try JSONDecoder().decode(RunSummary.self, from: summary.json), summary)
    }

    func test_theSummary_ofASuspectRun_givesTheScoreWithoutThem_andOfNothingTested_noScore() {
        let suspect = RunSummary(of: .withSuspectTests, ended: .interrupted, endDetail: "SIGINT", report: nil)
        XCTAssertEqual(suspect.mutationScore, 92)
        XCTAssertEqual(suspect.mutationScoreWithoutSuspectTests, 50)
        XCTAssertTrue(suspect.scoreWithoutSuspectsIsALowerBound)
        XCTAssertEqual(suspect.endDetail, "SIGINT")

        let empty = RunSummary(of: MutationTestOutcome(), ended: nil, report: nil)
        XCTAssertNil(empty.mutationScore)
        XCTAssertNil(empty.ended)
        XCTAssertEqual(empty.mutants, 0)
    }

    // A score of some shards isn't the whole run's, so the summary says which it covers.
    func test_theSummary_ofSomeShards_namesThem() throws {
        let scope = ShardScope(indices: [1], count: 3, mutantsInAllShards: 9)
        let summary = RunSummary(of: MutationTestOutcome(shards: scope), ended: .finished, report: nil)

        XCTAssertEqual(summary.shards, scope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: Any])
        let shards = try XCTUnwrap(json["shards"] as? [String: Any])
        XCTAssertEqual(shards["indices"] as? [Int], [1])
        XCTAssertEqual(shards["count"] as? Int, 3)
        XCTAssertEqual(try JSONDecoder().decode(RunSummary.self, from: summary.json), summary)
    }

    // The verdict on the score, for a script that gates on it without reading the text; only with a threshold.
    func test_theSummary_withAThreshold_holdsItsVerdict() throws {
        let outcome = MutationTestOutcome.make([.failed, .passed, .passed], failUnder: 50)
        let gate = ScoreGate(failUnder: 50, judging: outcome)
        let summary = RunSummary(of: outcome, ended: .finished, report: nil, gate: gate)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? NSDictionary)
        XCTAssertEqual(json["gate"] as? NSDictionary, ["failUnder": 50, "passed": false, "score": 100.0 / 3])
        let text = String(decoding: summary.json, as: UTF8.self)
        XCTAssertTrue(text.contains(#""failUnder" : 50,"#), text)
        XCTAssertEqual(try JSONDecoder().decode(RunSummary.self, from: summary.json), summary)
        let unchecked = RunSummary(
            of: outcome,
            ended: .aborted,
            report: nil,
            gate: ScoreGate(failUnder: 50, judging: outcome, unless: .endedEarly)
        )
        let uncheckedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: unchecked.json) as? NSDictionary)
        XCTAssertEqual(uncheckedJSON["gate"] as? NSDictionary, ["failUnder": 50, "notChecked": "endedEarly"])
        XCTAssertFalse(
            String(decoding: RunSummary(of: outcome, ended: .finished, report: nil).json, as: UTF8.self)
                .contains("gate")
        )
    }

    // Beside the results file, which a resumed run keeps in its first session's folder; without one, in the log
    // folder; nowhere without either.
    func test_theSummarysPath_isBesideTheResultsFile() {
        XCTAssertEqual(
            RunSummary.path(besideResultsFile: "/logs/run 1/results.jsonl", loggingDirectory: "/logs/run 2"),
            "/logs/run 1/summary.json"
        )
        XCTAssertEqual(
            RunSummary.path(besideResultsFile: nil, loggingDirectory: "/logs/run 2"),
            "/logs/run 2/summary.json"
        )
        XCTAssertNil(RunSummary.path(besideResultsFile: nil, loggingDirectory: ""))
    }
}
