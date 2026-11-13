/// A glob that picks out property tests among the tests a mutant's run recorded failing (`propertyTests:`,
/// `--property-tests`). It matches a test when it matches the whole of the test's name, as the results file records
/// it, or the whole of the file the test's issue was recorded in. So `*Properties*` matches Swift Testing's
/// `sortIsOrdered()` recorded in `SortProperties.swift`, and XCTest's `-[App.SortProperties testOrdered]`, whose
/// lines name no file. `*` stands for any characters, none included, and `?` for one; anything else matches itself,
/// case included.
struct PropertyTestPattern: Equatable {
    let glob: String

    init(_ glob: String) {
        self.glob = glob
    }

    func matches(_ test: FailedTestLine.TestIdentity) -> Bool {
        Self.matches(glob, test.name) || test.file.map { Self.matches(glob, $0) } == true
    }

    /// What is wrong with `globs`, as a configuration or a flag gives them; nil when nothing is.
    static func problem(with globs: [String]) -> String? {
        globs.contains(where: \.isEmpty) ? "a glob can't be empty, as it would match no test" : nil
    }

    /// Whether `glob` matches the whole of `text`, character by character, as Swift compares characters: `?` is one,
    /// whether a combined emoji or a letter with its accent.
    private static func matches(_ glob: String, _ text: String) -> Bool {
        let pattern = Array(glob)
        let characters = Array(text)
        // The classic backtracking match: on a mismatch, `*` takes one more character.
        var (patternIndex, textIndex) = (0, 0)
        var lastStar: (pattern: Int, text: Int)?
        while textIndex < characters.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                lastStar = (patternIndex, textIndex)
                patternIndex += 1
            } else if patternIndex < pattern.count,
                      pattern[patternIndex] == "?" || pattern[patternIndex] == characters[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if let star = lastStar {
                patternIndex = star.pattern + 1
                textIndex = star.text + 1
                lastStar = (star.pattern, star.text + 1)
            } else {
                return false
            }
        }
        return pattern[patternIndex...].allSatisfy { $0 == "*" }
    }
}

/// Which kind of test killed each mutant, example tests or property tests, as `propertyTests` tells them apart: the
/// kills only examples made, only properties made, and both made, and for each property the kills it made and those
/// only it made. Its counts are of the headline score's mutants, every one but a build error, timeouts included, so
/// its kills add up to the headline's killed count. It reads only what the runs recorded: a run stopped at its first
/// failed test records that test alone, so a property that would also have failed is hidden, and "only by examples"
/// may be "by both".
struct PropertyKillSummary: Codable, Equatable {
    /// How many properties the reports list.
    static let shownProperties = 10

    struct Property: Codable, Equatable {
        let name: String
        /// The file its issues were recorded in; none for XCTest's, whose lines give no location.
        let file: String?
        /// How many killed mutants it was recorded failing for.
        let mutants: Int
        /// How many of those it was the only test recorded failing for: the kills only it made, as far as the runs
        /// show. A run stopped at its first failed test may have had others to fail.
        let onlyRecordedKillerOf: Int
    }

    /// The globs that picked out the property tests.
    let globs: [String]
    /// The headline score's mutants: every one but a build error.
    let scoredMutants: Int
    /// Those a failed test or a crash killed, as the headline counts them.
    let killedMutants: Int
    let killedOnlyByExamples: Int
    let killedOnlyByProperties: Int
    let killedByBoth: Int
    /// Killed mutants that name no failed test: a crash, a run whose log shows none failing, or one whose tests weren't
    /// recorded.
    let killedNamingNoTest: Int
    /// Of the kills only by one kind, how many may not name every test that failed: their run stopped at its first
    /// failed test or its time limit, or more failed than a list holds. A test of the other kind may have failed too.
    let incompleteExampleOnlyKills: Int
    let incompletePropertyOnlyKills: Int
    /// Of the kills whose recorded tests are all examples, how many the property tests were run again for on their own
    /// (`propertyTestFilter`), and in how many of those a property test failed too, so they count as by both. The
    /// others' properties all passed, so they count as by examples alone, whatever their lists held. A rerun that
    /// timed out or didn't build settles nothing.
    let propertyReruns: Int
    let propertyRerunKills: Int
    let propertyRerunPasses: Int
    /// Of the kills whose recorded tests are all properties, in a list cut short, how many every test but the property
    /// tests was run again for, with them skipped (`propertyTestFilter`, SwiftPM only), and in how many of those an
    /// example failed too, so they count as by both. The others' tests all passed, so they count as by properties
    /// alone, whatever their lists held. A rerun that timed out, didn't build, crashed or only failed property tests
    /// settles nothing.
    let exampleReruns: Int
    let exampleRerunKills: Int
    let exampleRerunPasses: Int
    /// How many property tests failed for a killed mutant.
    let distinctProperties: Int
    /// The `shownProperties` that failed for the most killed mutants, then by name and file.
    let properties: [Property]

    /// Whether some kill only by one kind may hide a test of the other kind that failed too: the kills by both are
    /// then a lower bound, and the kills only by one kind upper bounds.
    var countsAreBounds: Bool {
        incompleteExampleOnlyKills + incompletePropertyOnlyKills > 0
    }
}
