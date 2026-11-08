@testable import muterCore
// As in PlainTextReporterTests: XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import TestingExtensions
import XCTest

/// The Markdown report (`-f markdown`): short enough for a GitHub job summary, and the same for the same outcome.
final class MarkdownReporterTests: MuterTestCase {
    private let project = URL(fileURLWithPath: "/work/Foo")
    private let copy = URL(fileURLWithPath: "/work/Foo_mutated")

    override func setUp() {
        super.setUp()
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    private func mutant(
        _ outcome: TestSuiteOutcome,
        _ path: String = "Sources/Rules.swift",
        line: Int,
        column: Int = 9,
        description: String = "changed == to !="
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: .ror,
                filePath: copy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: column)
            ),
            snapshot: .make(before: "==", after: "!=", description: description),
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: copy,
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: column, occurrence: 0)
        )
    }

    private func report(_ outcome: MutationTestOutcome) -> String {
        MarkdownReporter().report(from: outcome)
    }

    // Every mutant killed, with coverage gathered: no survivor to list, and the note on what coverage leaves out.
    func test_withoutSurvivors() {
        let outcome = MutationTestOutcome(
            mutations: [mutant(.failed, line: 2), mutant(.runtimeError, "Sources/Sum.swift", line: 7)],
            coverage: .make(percent: 80),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )

        AssertSnapshot(report(outcome))
    }

    // By file, then by line and column, each timeout said, each with its triage label; then the mutants not covered,
    // and a file no test ran as one row of its own.
    func test_withSurvivorsTimeoutsAndMutantsNotCovered() {
        let outcome = MutationTestOutcome(
            mutations: [
                mutant(.failed, line: 2),
                mutant(.timeout, line: 3, column: 14, description: "changed < to >"),
                mutant(.passed, "Sources/Rules.swift", line: 12),
                mutant(.passed, "Sources/Alpha.swift", line: 5),
                mutant(.noCoverage, "Sources/Alpha.swift", line: 9),
                mutant(.buildError, "Sources/Alpha.swift", line: 11),
            ],
            coverage: .make(percent: 64, filesWithoutCoverage: [copy.path + "/Sources/Unused.swift"]),
            triage: TriageFile(path: "/work/Foo/muter.triage.yml", entries: [
                TriageEntry(
                    mutant: MutantKey(
                        path: "Sources/Rules.swift", mutationOperatorId: .ror, line: 12, column: 9, occurrence: 0
                    ),
                    label: .equivalent,
                    note: "count can't exceed limit here",
                    before: "==",
                    after: "!="
                ),
            ]),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )

        AssertSnapshot(report(outcome))
    }

    // At most `mostListed` named, then how many more, which the JSON report lists; the counts cover them all.
    func test_aLongList_isCut() {
        let survivors = (1 ... 103).map { mutant(.passed, "Sources/File\($0 % 2).swift", line: $0) }
        let text = report(MutationTestOutcome(
            mutations: survivors,
            coverageSkipped: true,
            projectPath: project.path,
            mutatedProjectPath: copy.path
        ))

        XCTAssertEqual(text.components(separatedBy: "\n  - `").count - 1, MarkdownReporter.mostListed, text)
        XCTAssertTrue(text.contains("\n\n…and 3 more; the JSON report lists them all.\n"), text)
        XCTAssertTrue(text.contains("### Surviving mutants (103)"), text)
        XCTAssertFalse(text.contains("--skip-coverage` makes them all"), "coverage was skipped: \(text)")
    }

    // Every file no test ran has a row, a shard's run's too, so a large project's table is cut as the lists are, the
    // files with mutants first.
    func test_aLongTableOfFiles_isCut() {
        let unrun = (1 ... MarkdownReporter.mostFiles + 2).map { copy.path + "/Sources/Unrun\($0).swift" }
        let text = report(MutationTestOutcome(
            mutations: [mutant(.failed, line: 2)],
            coverage: .make(percent: 1, filesWithoutCoverage: unrun),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        ))

        XCTAssertEqual(text.components(separatedBy: "\n| `").count - 1, MarkdownReporter.mostFiles, text)
        XCTAssertTrue(text.contains("\n| `Sources/Rules.swift` | 1 | 100% |\n"), text)
        XCTAssertTrue(text.contains("|\n\n…and 3 more files; the JSON report lists them all.\n\n"), text)
    }

    // What paths, descriptions and labels hold is shown as it is, not read as Markdown.
    func test_textThatLooksLikeMarkdown_isEscaped() {
        let outcome = MutationTestOutcome(
            mutations: [
                mutant(.passed, "Sources/a|b `c`.swift", line: 4, description: "changed *a* to _b_ | <c> & $d"),
            ],
            coverage: .make(percent: 50),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )

        AssertSnapshot(report(outcome))
    }

    // The score without them, and every warning the run ends with, each in a quote of its own.
    func test_withSuspectTests_andWarnings() {
        var unproven = mutant(.failed, "Sources/Unproven.swift", line: 1)
        unproven.activated = false
        let suspects = MutationTestOutcome.withSuspectTests
        let outcome = MutationTestOutcome(
            mutations: suspects.mutations + [unproven, mutant(.buildError, "Sources/Broken.swift", line: 2)],
            coverageSkipped: true
        )

        AssertSnapshot(report(outcome))
    }

    // The verdict of each check the run was asked for, after the headline and warnings, with the new survivors in a
    // table whose cells stay cells.
    func test_theChecks_areShownNearTheTop() {
        var outcome = MutationTestOutcome(
            mutations: [mutant(.failed, line: 2), mutant(.passed, line: 4), mutant(.passed, line: 8)],
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )
        let gate = ScoreGate(failUnder: 50, judging: outcome)
        let newSurvivors = NewSurvivorsCheck(
            baseline: "muter.baseline.yml",
            maxNewSurvivors: 0,
            verdict: .checked(.init(
                newSurvivors: [
                    .init(mutant: "Sources/Rules.swift:4:9 RelationalOperatorReplacement", before: "==", after: "!="),
                    .init(
                        mutant: "Sources/Rules.swift:8:9 RelationalOperatorReplacement",
                        before: "a || b",
                        after: "a"
                    ),
                ],
                stillSurvive: 41,
                fixed: 3,
                notTested: 0,
                matchedWithoutLine: 0
            )),
            versionNotice: "The baseline file muter.baseline.yml was written by SwiftMutator 0.0.9, and these "
                + "survivors by 0.1.0: a new or changed operator's mutants may show as new survivors."
        )
        outcome.checks = RunChecks(scoreGate: gate, newSurvivors: newSurvivors)

        let markdown = report(outcome)

        AssertSnapshot(markdown)
        XCTAssertLessThan(
            markdown.range(of: "### Checks")?.lowerBound ?? markdown.endIndex,
            markdown.range(of: "### Scores by file")?.lowerBound ?? markdown.startIndex
        )
    }

    // A new survivor of code no test ran says so in its row, as the run's line does.
    func test_aNewSurvivorNoTestRan_isMarkedInTheChecksTable() {
        var outcome = MutationTestOutcome(mutations: [mutant(.passed, line: 4)])
        outcome.checks = RunChecks(newSurvivors: NewSurvivorsCheck(
            baseline: "muter.baseline.yml",
            maxNewSurvivors: 0,
            verdict: .checked(.init(
                newSurvivors: [
                    .init(mutant: "Sources/New.swift:4:9 RelationalOperatorReplacement", before: "<", after: ">"),
                    .init(
                        mutant: "Sources/New.swift:9:9 RelationalOperatorReplacement",
                        before: "*",
                        after: "/",
                        notCovered: true
                    ),
                ],
                stillSurvive: 0,
                fixed: 0,
                notTested: 0,
                matchedWithoutLine: 0
            ))
        ))

        let rows = report(outcome).split(separator: "\n").filter { $0.contains("Sources/New.swift") }

        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].contains("coverage left it out"), String(rows[0]))
        XCTAssertTrue(rows[1].hasSuffix("(coverage left it out) |"), String(rows[1]))
    }

    // A check that wasn't made, as for a run that ended early, shows nothing: such a report is as it was.
    func test_withoutChecks_thereIsNoChecksSection() {
        var outcome = MutationTestOutcome(mutations: [mutant(.passed, line: 4)])
        let plain = report(outcome)
        outcome.checks = RunChecks(
            newSurvivors: NewSurvivorsCheck(baseline: "b.yml", maxNewSurvivors: 0, verdict: .notChecked(.endedEarly))
        )

        XCTAssertFalse(plain.contains("### Checks"))
        XCTAssertEqual(report(outcome), plain)
    }

    func test_withoutMutants() {
        AssertSnapshot(report(MutationTestOutcome()))
    }

    // Each scope sentence the plain report gives, after the coverage.
    func test_saysWhatPartOfTheProjectWasTested() {
        let text = report(MutationTestOutcome(
            mutations: [mutant(.failed, line: 2)],
            shards: ShardScope(indices: [1], count: 2, mutantsInAllShards: 40),
            mutant: "Sources/Rules.swift:2:9 RelationalOperatorReplacement"
        ))

        XCTAssertTrue(
            text.contains("\n\nOnly the mutants in shard 1 of 2 were tested, of 40 discovered in every shard."), text
        )
        XCTAssertTrue(
            text.contains(
                "\n\nOne mutant chosen with --mutant (Sources/Rules.swift:2:9 RelationalOperatorReplacement): its "
                    + "score isn't the project's."
            ),
            text
        )
    }

    func test_markdownText_escapesPlainText_andFencesCode() {
        XCTAssertEqual(MarkdownText.plain("a*b_c`d\\e|f[g]<h>~i&j$k"), #"a\*b\_c\`d\\e\|f\[g\]\<h\>\~i\&j\$k"#)
        XCTAssertEqual(MarkdownText.plain("two\nlines"), "two lines")
        XCTAssertEqual(MarkdownText.code("Sources/A.swift"), "`Sources/A.swift`")
        XCTAssertEqual(MarkdownText.code("a `b` c"), "``a `b` c``")
        XCTAssertEqual(MarkdownText.code("`a``"), "``` `a`` ```")
        XCTAssertEqual(MarkdownText.code(" a "), "`  a  `")
        XCTAssertEqual(MarkdownText.codeInCell("a|b"), #"`a\|b`"#)
    }
}
