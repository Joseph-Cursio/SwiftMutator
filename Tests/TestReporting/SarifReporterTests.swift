@testable import muterCore
import TestingExtensions
import XCTest

/// The SARIF report (`-f sarif`), for GitHub code scanning: the mutants the tests didn't kill, the same for the same
/// outcome and files.
final class SarifReporterTests: MuterTestCase {
    private typealias Fixture = ToolReportFixture

    override func setUp() {
        super.setUp()
        current.readSourceFile = Fixture.read
    }

    private func report(_ outcome: MutationTestOutcome, mostResults: Int = 25_000) -> String {
        SarifReporter(swiftMutatorVersion: "1.2.3", mostResults: mostResults).report(from: outcome)
    }

    private func run(_ outcome: MutationTestOutcome, mostResults: Int = 25_000) throws -> SarifLog.Run {
        let log = try JSONDecoder().decode(SarifLog.self, from: Data(report(outcome, mostResults: mostResults).utf8))
        XCTAssertEqual(log.runs.count, 1)
        return try XCTUnwrap(log.runs.first)
    }

    // Survivors, a timeout and a mutant not covered; a file that can't be read, one outside the project, and a
    // project whose path has a space.
    func test_everyOutcome() {
        AssertSnapshot(report(Fixture.everyOutcome))
    }

    // Survivors and timeouts are warnings, a mutant not covered a note, and nothing else is a result. Each names its
    // rule by id and by its place among the rules.
    func test_results_areTheMutantsTheTestsDidntKill() throws {
        let run = try run(Fixture.everyOutcome)
        let rules = run.tool.driver.rules

        XCTAssertEqual(rules.map(\.id), ["RelationalOperatorReplacement", "RemoveSideEffects", "SwapTernary"])
        XCTAssertEqual(rules.first?.shortDescription.text, "Relational Operator Replacement")
        XCTAssertEqual(rules.first?.help.text, MutationOperator.Id.ror.explanation)
        XCTAssertEqual(run.results.map { "\($0.level.rawValue) \($0.message.text)" }, [
            "warning Your test suite did not kill this mutant: changed == to !=",
            "warning Your test suite did not kill this mutant: changed < to >",
            "warning Your test suite did not kill this mutant: swapped ternary (timed out)",
            "note No test reached this mutant: removed line",
        ])
        for result in run.results {
            XCTAssertEqual(rules[result.ruleIndex].id, result.ruleId)
        }
        XCTAssertEqual(run.invocations, [.init(executionSuccessful: true, toolExecutionNotifications: nil)])
        XCTAssertNil(run.properties)
    }

    // Relative to %SRCROOT%, the project's file URI; a file outside it by its own. UTF-16 columns where the file was
    // read, over the code the mutant changes, wherever its operator placed it, with that code as the region's snippet
    // and its lines whole as the context's.
    func test_locations() throws {
        let outcome = Fixture.outcome([
            Fixture.mutant(.passed, line: 2, column: 25),
            Fixture.mutant(.passed, line: 3, column: 14, before: "<", after: ">"),
            Fixture.mutant(
                .passed, .logicalOperator, "Sources/Other.swift", line: 4, column: 9, before: "&&", after: "||"
            ),
            Fixture.mutant(.passed, .ror, "/elsewhere/Shared.swift", line: 1, column: 14),
            Fixture.mutant(
                .passed,
                .logicalOperator,
                line: Fixture.andPlace.line,
                column: Fixture.andPlace.column,
                before: "&&",
                after: "||"
            ),
            Fixture.mutant(
                .passed,
                .swapTernary,
                line: Fixture.ternaryEnd.line,
                column: Fixture.ternaryEnd.column,
                before: Fixture.ternary,
                after: "flag ? 2 : 1"
            ),
        ])
        let run = try run(outcome)
        let locations = run.results.compactMap { $0.locations.first?.physicalLocation }

        XCTAssertEqual(run.originalUriBaseIds, ["%SRCROOT%": .init(uri: "file:///work/My%20Foo/", uriBaseId: nil)])
        XCTAssertEqual(run.columnKind, "utf16CodeUnits")
        XCTAssertEqual(locations.map(\.artifactLocation), [
            .init(uri: "file:///elsewhere/Shared.swift", uriBaseId: nil),
            .init(uri: "Sources/Other.swift", uriBaseId: "%SRCROOT%"),
            .init(uri: "Sources/Rules.swift", uriBaseId: "%SRCROOT%"),
            .init(uri: "Sources/Rules.swift", uriBaseId: "%SRCROOT%"),
            .init(uri: "Sources/Rules.swift", uriBaseId: "%SRCROOT%"),
            .init(uri: "Sources/Rules.swift", uriBaseId: "%SRCROOT%"),
        ])
        XCTAssertEqual(locations.map(\.region), [
            .init(startLine: 1, startColumn: 14, endLine: 1, endColumn: 16, snippet: .init(text: "==")),
            .init(startLine: 4, startColumn: 9, endLine: 4, endColumn: 11, snippet: nil),
            .init(startLine: 2, startColumn: 24, endLine: 2, endColumn: 26, snippet: .init(text: "==")),
            .init(startLine: 3, startColumn: 14, endLine: 3, endColumn: 15, snippet: .init(text: "<")),
            .init(
                startLine: 6,
                startColumn: 5,
                endLine: 8,
                endColumn: 12,
                snippet: .init(text: "flag\n        ? 1\n        : 2")
            ),
            .init(startLine: 12, startColumn: 9, endLine: 12, endColumn: 11, snippet: .init(text: "&&")),
        ])
        XCTAssertEqual(locations.map(\.contextRegion), [
            .init(startLine: 1, endLine: 1, snippet: .init(text: "let same = a == b")),
            nil,
            .init(startLine: 2, endLine: 2, snippet: .init(text: "    let café = 1; if a == b { return true }")),
            .init(startLine: 3, endLine: 3, snippet: .init(text: "    return a < b")),
            .init(startLine: 6, endLine: 8, snippet: .init(text: "    flag\n        ? 1\n        : 2")),
            .init(startLine: 12, endLine: 12, snippet: .init(text: "        && b")),
        ])
    }

    // Paths are from the root of the work tree the project is in, as GitHub reads them from the repository's.
    func test_paths_areFromTheWorkTreesRoot() throws {
        current.projectInWorkTree = { _ in .init(root: "/work", projectFolder: "My Foo") }
        let outcome = Fixture.outcome([
            Fixture.mutant(.passed, line: 2, column: 25),
            Fixture.mutant(.passed, .ror, "/elsewhere/Shared.swift", line: 1, column: 14),
        ])
        let run = try run(outcome)

        XCTAssertEqual(run.originalUriBaseIds, ["%SRCROOT%": .init(uri: "file:///work/", uriBaseId: nil)])
        XCTAssertEqual(run.results.compactMap { $0.locations.first?.physicalLocation.artifactLocation }, [
            .init(uri: "file:///elsewhere/Shared.swift", uriBaseId: nil),
            .init(uri: "My%20Foo/Sources/Rules.swift", uriBaseId: "%SRCROOT%"),
        ])

        current.projectInWorkTree = { .init(root: $0, projectFolder: "") }
        XCTAssertEqual(
            try self.run(outcome).results.last?.locations.first?.physicalLocation.artifactLocation.uri,
            "Sources/Rules.swift"
        )
    }

    // The project's folder in its work tree, from the folder the run recorded, or from the current one when that is
    // gone, as for a results file from another machine, and never from what is left of the old path.
    func test_aProjectsPlaceInItsWorkTree_isFromAFolderThatIsThere() {
        let there: Set = ["/repo/.git", "/repo/packages/Core", "/home/.git", "/home/me/clone/.git"]
        let place = { (recorded: String, current: String) in
            WorkTree.place(of: recorded, currentFolder: current, fileExists: there.contains)
        }

        XCTAssertEqual(place("/repo/packages/Core", "/elsewhere"), .init(root: "/repo", projectFolder: "packages/Core"))
        XCTAssertEqual(
            place("/home/runner/work/R/R/packages/Core", "/home/me/clone/packages/Core"),
            .init(root: "/home/me/clone", projectFolder: "packages/Core")
        )
        XCTAssertEqual(place("/repo/packages/Gone", "/home/me/clone"), .init(root: "/home/me/clone", projectFolder: ""))
        XCTAssertNil(place("/gone/Project", "/elsewhere"))
    }

    // The nearest folder up that holds a `.git`, whether a folder or a linked work tree's file.
    func test_aWorkTreesRoot_isTheNearestFolderWithAGit() {
        let gits: Set = ["/repo/.git", "/repo/packages/Linked/.git"]
        let root = { WorkTree.root(containing: $0, fileExists: gits.contains) }

        XCTAssertEqual(root("/repo/packages/Core"), "/repo")
        XCTAssertEqual(root("/repo/packages/Linked/Sources/"), "/repo/packages/Linked")
        XCTAssertEqual(root("/repo"), "/repo")
        XCTAssertNil(root("/elsewhere/Project"))
    }

    func test_aPath_isEncodedAsAURI() {
        XCTAssertEqual(
            SarifFinding.artifactLocation(of: "Sources/My File#1:a é.swift"),
            .init(uri: "Sources/My%20File%231%3Aa%20%C3%A9.swift", uriBaseId: "%SRCROOT%")
        )
        XCTAssertEqual(
            SarifFinding.artifactLocation(of: "/other place/a.swift"),
            .init(uri: "file:///other%20place/a.swift", uriBaseId: nil)
        )
    }

    // Survivors first: past the cap, the warnings are kept before any note, and the run says how many were left out.
    func test_theCap_keepsSurvivorsFirst_andSaysHowManyItLeftOut() throws {
        AssertSnapshot(report(Fixture.everyOutcome, mostResults: 2))

        let cut = try run(Fixture.everyOutcome, mostResults: 3)
        XCTAssertEqual(cut.results.map(\.level), [.warning, .warning, .warning])
        XCTAssertEqual(cut.properties, SarifLog.Properties(resultsLeftOut: 1))
        XCTAssertEqual(cut.invocations.first?.toolExecutionNotifications?.first?.message.text, "SwiftMutator left "
            + "out 1 of 4 results, as GitHub code scanning takes at most 3 from a run: the mutants that survived or "
            + "timed out come first, then those no test reached.")
        XCTAssertEqual(cut.tool.driver.rules.map(\.id), ["RelationalOperatorReplacement", "SwapTernary"])

        let whole = try run(Fixture.everyOutcome, mostResults: 4)
        XCTAssertNil(whole.properties)
        XCTAssertNil(whole.invocations.first?.toolExecutionNotifications)
    }

    // A fingerprint is of what a mutant changes, never of where, so an edit above its line keeps it. It is also the
    // line hash, the only fingerprint GitHub reads.
    func test_aFingerprint_staysWhenItsLineMoves() throws {
        let moved = "// A comment.\n\n" + Fixture.rules
        let fingerprint = { (text: String, line: Int) in
            current.readSourceFile = { _ in Data(text.utf8) }
            let run = try self.run(Fixture.outcome([Fixture.mutant(.passed, line: line, column: 25)]))
            let fingerprints = try XCTUnwrap(run.results.first?.partialFingerprints)
            XCTAssertEqual(fingerprints["primaryLocationLineHash"], fingerprints["swiftMutatorMutant/v1"])
            return try XCTUnwrap(fingerprints["swiftMutatorMutant/v1"])
        }

        let before = try fingerprint(Fixture.rules, 2)
        XCTAssertEqual(try fingerprint(moved, 4), before)
        XCTAssertEqual(before.count, 64)
        XCTAssertNotEqual(try fingerprint(Fixture.rules.replacingOccurrences(of: "café", with: "cafe"), 2), before)
    }

    // Two of one change on lines alike are told apart by how many such lines are above, and two on one line by where
    // each starts. Both are counted in the file, so a run that tests only some of them, as a shard or `--since` may,
    // gives each the fingerprint a whole run does.
    func test_repeatsOfOneChange_haveFingerprintsOfTheirOwn() throws {
        current.readSourceFile = { _ in Data("if a == b {}\nif a == b {}\nlet c = a == b || a == b\n".utf8) }
        let fingerprints = { (mutants: [MutationTestOutcome.Mutation]) in
            try self.run(Fixture.outcome(mutants)).results
                .compactMap { $0.partialFingerprints["swiftMutatorMutant/v1"] }
        }
        let first = Fixture.mutant(.passed, line: 1, column: 6)
        let second = Fixture.mutant(.passed, line: 2, column: 6)
        let left = Fixture.mutant(.passed, line: 3, column: 11)
        let right = Fixture.mutant(.passed, line: 3, column: 21)

        let all = try fingerprints([first, second, left, right])
        XCTAssertEqual(Set(all).count, 4)
        XCTAssertEqual(try fingerprints([second, right]), [all[1], all[3]])
        XCTAssertEqual(try fingerprints([Fixture.mutant(.failed, line: 1, column: 6), second]), [all[1]])

        // Changed since, the line no longer holds their code, and each spans it whole: their recorded places still
        // tell them apart, so GitHub doesn't take them for one alert.
        current.readSourceFile = { _ in Data("let c = a != b || a != b\n".utf8) }
        let unfound = [Fixture.mutant(.passed, line: 1, column: 11), Fixture.mutant(.passed, line: 1, column: 21)]
        XCTAssertEqual(Set(try fingerprints(unfound)).count, 2)
    }

    func test_withoutResults() throws {
        let run = try run(Fixture.outcome([Fixture.mutant(.failed, line: 2, column: 25)]))

        XCTAssertEqual(run.results, [])
        XCTAssertEqual(run.tool.driver.rules, [])
        XCTAssertEqual(run.tool.driver.name, "SwiftMutator")
        XCTAssertEqual(run.tool.driver.version, "1.2.3")
        XCTAssertEqual(run.tool.driver.informationUri, "https://github.com/Joseph-Cursio/SwiftMutator")
    }
}
