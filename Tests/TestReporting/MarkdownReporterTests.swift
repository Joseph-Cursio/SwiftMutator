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
