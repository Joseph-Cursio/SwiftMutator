@testable import muterCore
// As in PlainTextReporterTests: XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

/// The survivors first, each at its place by its path in the project, with the line it changes; and every report's
/// counts by outcome.
final class ReadableReportTests: MuterTestCase {
    private let project = URL(fileURLWithPath: "/work/Foo")
    private let copy = URL(fileURLWithPath: "/work/Foo_mutated")
    private let rules = """
    func allows(_ a: Int, _ b: Int) -> Bool {
        if a == b && a > 0 { return true }
        return a < b
    }

    """

    override func setUp() {
        super.setUp()
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    private func mutant(
        _ outcome: TestSuiteOutcome,
        _ path: String,
        line: Int,
        column: Int,
        _ snapshot: MutationOperator.Snapshot = .make(before: "==", after: "!=", description: "changed == to !=")
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: .ror,
                filePath: copy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: column)
            ),
            snapshot: snapshot,
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: copy
        )
    }

    private func outcome(
        _ mutations: [MutationTestOutcome.Mutation],
        digests: [String: String]? = nil
    ) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            projectPath: project.path,
            mutatedProjectPath: copy.path,
            sourceDigests: digests
        )
    }

    /// Reads `rules` as the original Sources/Rules.swift, and nothing else.
    private func readingRules() -> ReadFile {
        { [rules, project] path in path == project.path + "/Sources/Rules.swift" ? Data(rules.utf8) : nil }
    }

    // The survivors and the timeouts, which the score counts as survivors, by path, line and column as numbers;
    // never a kill or a build error.
    func test_survivors_areThoseTheScoreCounts_byPathLineAndColumn() {
        let report = MuterTestReport(from: outcome([
            mutant(.passed, "Sources/Rules.swift", line: 10, column: 4),
            mutant(.failed, "Sources/Rules.swift", line: 2, column: 10),
            mutant(.timeout, "Sources/Rules.swift", line: 9, column: 12),
            mutant(.passed, "Sources/Rules.swift", line: 9, column: 5),
            mutant(.buildError, "Sources/A.swift", line: 1, column: 1),
            mutant(.passed, "Sources/Lint/Rules.swift", line: 3, column: 1),
        ]))

        XCTAssertEqual(
            report.survivors.map { MuterTestReport.place($0.appliedOperator, in: $0.relativePath) },
            [
                "Sources/Lint/Rules.swift:3:1",
                "Sources/Rules.swift:9:5",
                "Sources/Rules.swift:9:12",
                "Sources/Rules.swift:10:4",
            ]
        )
    }

    // Two files of one name are told apart by their paths, in every table of the plain and HTML reports.
    func test_theReports_nameEachFileByItsPathInTheProject() {
        let outcome = outcome([
            mutant(.passed, "Sources/Lint/Rules.swift", line: 3, column: 1),
            mutant(.failed, "Sources/Rules.swift", line: 2, column: 10),
        ])

        let plainText = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(plainText.contains("\nSources/Lint/Rules.swift:3:1 survived: RelationalOperatorReplacement "
            + "(changed == to !=)\n"), plainText)
        XCTAssertTrue(plainText.contains("\nSources/Rules.swift:2:10 "), plainText)
        XCTAssertTrue(plainText.contains("\nSources/Lint/Rules.swift   1 "), plainText)
        XCTAssertFalse(plainText.contains("/work/"), plainText)
        let html = HTMLReporter().report(from: outcome)
        XCTAssertTrue(html.contains(">Sources/Lint/Rules.swift:3:1</td>"), html)
        XCTAssertTrue(html.contains(">Sources/Rules.swift</td>"), html)
    }

    // Stryker's report keys each file by its path in the project, with its text; SARIF gives it relative to
    // %SRCROOT%, with the code the survivor changes and its line.
    func test_theStrykerAndSarifReports_nameEachFileByItsPathInTheProject() throws {
        current.readSourceFile = readingRules()
        let outcome = outcome([
            mutant(.passed, "Sources/Rules.swift", line: 2, column: 10),
            mutant(.failed, "Sources/Lint/Rules.swift", line: 3, column: 1),
        ])

        let stryker = StrykerReporter().strykerReport(of: outcome)
        XCTAssertEqual(stryker.files.keys.sorted(), ["Sources/Lint/Rules.swift", "Sources/Rules.swift"])
        XCTAssertEqual(stryker.files["Sources/Rules.swift"]?.source, rules)
        XCTAssertEqual(stryker.projectRoot, "/work/Foo")
        let sarif = try XCTUnwrap(SarifReporter().sarifLog(of: outcome).runs.first)
        let location = try XCTUnwrap(sarif.results.first?.locations.first?.physicalLocation)
        XCTAssertEqual(sarif.results.count, 1)
        XCTAssertEqual(location.artifactLocation, .init(uri: "Sources/Rules.swift", uriBaseId: "%SRCROOT%"))
        XCTAssertEqual(location.region.snippet?.text, "==")
        XCTAssertEqual(location.contextRegion?.snippet.text, "    if a == b && a > 0 { return true }")
        XCTAssertEqual(sarif.originalUriBaseIds?["%SRCROOT%"]?.uri, "file:///work/Foo/")
    }

    // A file without coverage is named by its path in the copy, or in the project.
    func test_aFileWithoutCoverage_isNamedByItsPathInTheProject() {
        let outcome = MutationTestOutcome(
            coverage: .make(
                percent: 50,
                filesWithoutCoverage: [copy.path + "/Sources/A.swift", project.path + "/B.swift"]
            ),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )

        XCTAssertEqual(MuterTestReport(from: outcome).fileReports.map(\.relativePath), ["Sources/A.swift", "B.swift"])
    }

    // The line comes from the original file, never the copy, whose code holds every switch.
    func test_eachMutantsLine_comesFromItsOriginalFile_beforeAndAfter() throws {
        let report = MuterTestReport(
            from: outcome([mutant(.passed, "Sources/Rules.swift", line: 2, column: 10)]),
            readingSourcesWith: readingRules()
        )

        let change = try XCTUnwrap(report.fileReports.first?.appliedOperators.first?.sourceChange)
        XCTAssertEqual(change, SourceChange(
            line: 2,
            before: "    if a == b && a > 0 { return true }",
            after: "    if a != b && a > 0 { return true }"
        ))
    }

    // A file that changed since it was tested may have moved the mutant's line: its snapshot is shown instead. One
    // whose hash wasn't recorded is taken to be as it was.
    func test_aFileThatChangedSinceItWasTested_showsNoLine() {
        let survivor = mutant(.passed, "Sources/Rules.swift", line: 2, column: 10)
        let change = { (digests: [String: String]?) in
            MuterTestReport(from: self.outcome([survivor], digests: digests), readingSourcesWith: self.readingRules())
                .fileReports.first?.appliedOperators.first?.sourceChange
        }

        XCTAssertNotNil(change(["Sources/Rules.swift": FileDigest.sha256(of: Data(rules.utf8))]))
        XCTAssertNil(change(["Sources/Rules.swift": "another file's hash"]))
        XCTAssertNotNil(change(["Sources/Other.swift": "another file's hash"]))
        XCTAssertNotNil(change(nil))
    }

    // `report` checks a file against the hash its results file recorded, except for a test plan's session, which
    // records its rewritten copy.
    func test_theOutcomeFromAResultsFile_checksTheProjectsHashes() {
        let tree = ProjectTree(listedBy: .git, files: ["Sources/Rules.swift": "5a1c"], excluded: [], treeSHA256: "e5b8")
        let outcome = { (usingTestPlan: Bool) in
            MutationTestOutcome(
                records: [MutantResult](),
                under: .make(project: tree, usingTestPlan: usingTestPlan),
                testDuration: 0,
                shards: nil,
                sampleIsCutShort: false,
                controlRuns: []
            )
        }

        XCTAssertEqual(outcome(false).sourceDigests, tree.files)
        XCTAssertEqual(outcome(false).projectPath, "/project")
        XCTAssertEqual(outcome(false).mutatedProjectPath, "/project_mutated")
        XCTAssertNil(outcome(true).sourceDigests)
    }

    // Without a hash to check the file against, as for `report` of a test plan's run or a file that is a symbolic
    // link, a change is taken only at the mutant's own line and column: a file edited since could hold the same
    // operator on a line nearby. A file whose hash matches is as it was, so the only change on the mutant's line is
    // its own, wherever its column is.
    func test_aFileWhoseHashIsUnknown_showsALineOnlyAtTheMutantsPlace() {
        let tested = "func f(_ a: Int, _ b: Int) -> Bool {\n    let small = a < 10\n    return a < b && small\n}\n"
        // A line inserted above moves `return a < b` to line 4, and puts `let small = a < 10` on line 3.
        let edited = "// A comment.\n" + tested
        let change = { (text: String, column: Int, digests: [String: String]?) in
            MuterTestReport(
                from: self.outcome(
                    [self.mutant(.passed, "Sources/F.swift", line: 3, column: column, .make(before: "<", after: ">"))],
                    digests: digests
                ),
                readingSourcesWith: { _ in Data(text.utf8) }
            ).fileReports.first?.appliedOperators.first?.sourceChange
        }
        let link = ["Sources/F.swift": ProjectTree.linkPrefix + "9a9a"]

        XCTAssertNil(change(edited, 14, nil), "the `<` on line 3 is another statement's")
        XCTAssertNil(change(edited, 14, link))
        XCTAssertEqual(change(tested, 14, nil)?.before, "    return a < b && small")
        XCTAssertEqual(change(tested, 14, link)?.before, "    return a < b && small")
        XCTAssertNil(change(tested, 1, nil))
        XCTAssertEqual(
            change(tested, 1, ["Sources/F.swift": FileDigest.sha256(of: Data(tested.utf8))])?.before,
            "    return a < b && small"
        )
    }

    // Each file is read once, however many mutants it holds.
    func test_eachOriginalFile_isReadOnce() {
        let reads = Locked<[String]>([])
        let read: ReadFile = { [rules] path in
            reads.change { $0.append(path) }
            return Data(rules.utf8)
        }

        _ = MuterTestReport(
            from: outcome([
                mutant(.passed, "Sources/Rules.swift", line: 2, column: 10),
                mutant(.failed, "Sources/Rules.swift", line: 3, column: 14, .make(before: "<", after: ">")),
            ]),
            readingSourcesWith: read
        )

        XCTAssertEqual(reads.value, ["/work/Foo/Sources/Rules.swift"])
    }

    // The plain report gives each survivor's line under its place; the HTML report gives it, escaped, in place of the
    // snapshot; the JSON report holds it under `sourceChange`.
    func test_everyReport_showsTheLineASurvivorChanges() throws {
        current.readSourceFile = readingRules()
        let outcome = outcome([
            mutant(.passed, "Sources/Rules.swift", line: 2, column: 10),
            mutant(.passed, "Sources/Rules.swift", line: 3, column: 14, .make(before: "<", after: ">")),
        ])

        let plainText = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(plainText.contains("""
        Sources/Rules.swift:2:10 survived: RelationalOperatorReplacement (changed == to !=)
            -2:     if a == b && a > 0 { return true }
            +2:     if a != b && a > 0 { return true }
        Sources/Rules.swift:3:14 survived: RelationalOperatorReplacement
            -3:     return a < b
            +3:     return a > b

        """), plainText)

        // The Markdown report, kept short, names each by its place in its file, and leaves the line to the others.
        let markdown = MarkdownReporter().report(from: outcome)
        XCTAssertTrue(markdown.contains("""
        - `Sources/Rules.swift`
          - `2:10` RelationalOperatorReplacement: changed == to !=
          - `3:14` RelationalOperatorReplacement

        """), markdown)

        let html = HTMLReporter().report(from: outcome)
        XCTAssertTrue(html.contains(#"<div class="source-line snapshot-before">-3:     return a &lt; b</div>"#), html)
        XCTAssertTrue(html.contains(#"<div class="source-line snapshot-after">+3:     return a &gt; b</div>"#), html)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        let fileReports = try XCTUnwrap(json["fileReports"] as? [[String: Any]])
        let operators = try XCTUnwrap(fileReports.first?["appliedOperators"] as? [[String: Any]])
        XCTAssertEqual(operators.last?["sourceChange"] as? NSDictionary, [
            "line": 3,
            "before": "    return a < b",
            "after": "    return a > b",
        ] as NSDictionary)
    }

    // A removed statement that leaves only spaces on its line has no line after.
    func test_aRemovedLine_hasNoLineAfter() throws {
        let source = "func run() {\n    save()\n}\n"
        let change = try XCTUnwrap(MutantDiff.change(
            original: source,
            snapshot: .make(before: "save()", after: "removed line"),
            mutationOperatorId: .removeSideEffects,
            line: 2,
            column: 5
        ))

        XCTAssertEqual(change, SourceChange(line: 2, before: "    save()", after: nil))
        XCTAssertEqual(change.lines, ["-2:     save()"])
    }

    func test_withoutSurvivors_theReportsSaySo() {
        let outcome = outcome([mutant(.failed, "Sources/Rules.swift", line: 2, column: 10)])

        XCTAssertTrue(PlainTextReporter().report(from: outcome).contains("\nNo mutant survived or timed out.\n"))
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("<p>No mutant survived or timed out.</p>"))
        XCTAssertTrue(MarkdownReporter().report(from: outcome).contains("\n\nNo mutant survived or timed out.\n"))
    }

    // As the progress lines count them: a crash is a kill, and only the verdicts some mutant came to are named.
    func test_theCountsByOutcome_areInEveryReport() throws {
        let outcome = outcome([
            mutant(.failed, "A.swift", line: 1, column: 1),
            mutant(.runtimeError, "A.swift", line: 2, column: 1),
            mutant(.passed, "A.swift", line: 3, column: 1),
            mutant(.timeout, "A.swift", line: 4, column: 1),
            mutant(.buildError, "A.swift", line: 5, column: 1),
            mutant(.buildError, "A.swift", line: 6, column: 1),
        ])
        let tally = "2 killed, 1 survived, 1 timed out, 2 build errors"

        XCTAssertEqual(MuterTestReport(from: outcome).mutantsByOutcome, OutcomeCounts(
            killed: 2, survived: 1, timedOut: 1, buildErrors: 2
        ))
        XCTAssertTrue(PlainTextReporter().report(from: outcome).contains("\nBy outcome: \(tally)\n"))
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("📊 By outcome: \(tally)."))
        XCTAssertTrue(XcodeReporter().report(from: outcome).contains("\nMutants by outcome: \(tally)"))
        let markdown = MarkdownReporter().report(from: outcome)
        XCTAssertTrue(markdown.contains("\n**Mutation score: 50% (\(tally))**\n"), markdown)
        XCTAssertTrue(markdown.contains("""
        | Killed | Survived | Timed out | Build errors | Total |
        | ---: | ---: | ---: | ---: | ---: |
        | 2 | 1 | 1 | 2 | 6 |
        """), markdown)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["mutantsByOutcome"] as? NSDictionary, [
            "killed": 2, "survived": 1, "timedOut": 1, "buildErrors": 2, "notCovered": 0,
        ] as NSDictionary)
        XCTAssertEqual(MuterTestReport.scoreLine(of: outcome), "Mutation score: 50% (\(tally))")
    }

    func test_theScoreLine_ofARunThatTestedNothing_saysSo() {
        XCTAssertEqual(MuterTestReport.scoreLine(of: .make()), "Mutation score: none, as no mutant was tested")
    }
}
