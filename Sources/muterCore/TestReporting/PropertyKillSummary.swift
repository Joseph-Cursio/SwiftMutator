import Foundation

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
    /// How many property tests failed for a killed mutant.
    let distinctProperties: Int
    /// The `shownProperties` that failed for the most killed mutants, then by name and file.
    let properties: [Property]
}

extension PropertyKillSummary {
    /// The split of `mutations`' kills by the property tests `globs` pick out: nil without globs.
    init?(of mutations: [MutationTestOutcome.Mutation], globs: [String]) {
        guard !globs.isEmpty else { return nil }
        let patterns = globs.map(PropertyTestPattern.init)
        let isProperty = { (test: FailedTestLine.TestIdentity) in patterns.contains { $0.matches(test) } }

        let killed = mutations.filter { $0.testSuiteOutcome == .failed || $0.testSuiteOutcome == .runtimeError }
        var (examplesOnly, propertiesOnly, both, namingNone) = (0, 0, 0, 0)
        var (examplesOnlyIncomplete, propertiesOnlyIncomplete) = (0, 0)
        var (reruns, rerunKills, rerunPasses) = (0, 0, 0)
        var tallies: [FailedTestLine.TestIdentity: (mutants: Int, only: Int)] = [:]
        for mutation in killed {
            let tests = Set((mutation.killingTests?.tests ?? []).map(FailedTestLine.TestIdentity.init))
            guard !tests.isEmpty else {
                namingNone += 1
                continue
            }
            var properties = tests.filter(isProperty)
            let isComplete = mutation.killingTests?.isComplete == true
            let rerun = properties.isEmpty ? mutation.propertyRerun : nil
            if let rerun {
                reruns += 1
                if rerun.killed { rerunKills += 1 }
                if rerun.outcome == .passed { rerunPasses += 1 }
            }
            switch (properties.isEmpty, properties.count == tests.count) {
            case (true, _) where rerun?.killed == true:
                both += 1
                // The properties the rerun saw failing killed it too, with the examples its own run recorded.
                properties = Set((rerun?.killingTests?.tests ?? []).map(FailedTestLine.TestIdentity.init))
                    .filter(isProperty)
            case (true, _):
                examplesOnly += 1
                // Every property passed with it on, so no property was hidden, however the list was cut short.
                if !isComplete, rerun?.outcome != .passed { examplesOnlyIncomplete += 1 }
            case (false, true):
                propertiesOnly += 1
                if !isComplete { propertiesOnlyIncomplete += 1 }
            case (false, false):
                both += 1
            }
            for property in properties {
                tallies[property, default: (0, 0)].mutants += 1
                // The count, not the list: more may have failed than it holds. Never a rerun's, as an example failed.
                if rerun == nil, mutation.killingTests?.count == 1 { tallies[property, default: (0, 0)].only += 1 }
            }
        }
        // A total order, so every report lists the same properties the same way.
        let ranked = tallies
            .sorted { ($1.value.mutants, $0.key) < ($0.value.mutants, $1.key) }
            .map { identity, tally in
                Property(
                    name: identity.name, file: identity.file, mutants: tally.mutants, onlyRecordedKillerOf: tally.only
                )
            }

        self.init(
            globs: globs,
            scoredMutants: mutations.count { $0.testSuiteOutcome != .buildError },
            killedMutants: killed.count,
            killedOnlyByExamples: examplesOnly,
            killedOnlyByProperties: propertiesOnly,
            killedByBoth: both,
            killedNamingNoTest: namingNone,
            incompleteExampleOnlyKills: examplesOnlyIncomplete,
            incompletePropertyOnlyKills: propertiesOnlyIncomplete,
            propertyReruns: reruns,
            propertyRerunKills: rerunKills,
            propertyRerunPasses: rerunPasses,
            distinctProperties: ranked.count,
            properties: Array(ranked.prefix(Self.shownProperties))
        )
    }

    /// Whether some kill only by one kind may hide a test of the other kind that failed too: the kills by both are
    /// then a lower bound, and the kills only by one kind upper bounds.
    var countsAreBounds: Bool {
        incompleteExampleOnlyKills + incompletePropertyOnlyKills > 0
    }
}

/// What the plain and HTML reports' Examples and Properties section says. Never "killed" and a number at the start of
/// a line: scripts read the killed count from the one line that says so.
extension PropertyKillSummary {
    static let introduction = "Which kind of test killed each mutant: example tests or property tests. Each share is "
        + "of the mutants the headline score is of."

    /// "Property tests are those whose name or file matches "*Properties*" or "SortSpec.swift"."
    var globSentence: String {
        let quoted = globs.map { "\"\($0)\"" }
        let listed = quoted.count > 1
            ? quoted.dropLast().joined(separator: ", ") + " or " + (quoted.last ?? "")
            : quoted.joined()
        return "Property tests are those whose name or file matches \(listed)."
    }

    /// The split, each part with its share of the scored mutants, truncated as the headline score is.
    var splitSentences: [String] {
        let share = { (count: Int) in
            exactMutationScore(killed: count, of: scoredMutants).map { " (\(Int($0))%)" } ?? ""
        }
        let mutants = scoredMutants == 1 ? "1 mutant" : "\(scoredMutants) mutants"
        var sentences = [
            "Of the \(mutants) scored, examples alone were recorded killing \(killedOnlyByExamples)"
                + "\(share(killedOnlyByExamples)), properties alone \(killedOnlyByProperties)"
                + "\(share(killedOnlyByProperties)), and both \(killedByBoth)\(share(killedByBoth)).",
        ]
        if propertyReruns > 0 {
            let kills = propertyReruns == 1 ? "1 kill" : "\(propertyReruns) kills"
            let unsettled = propertyReruns - propertyRerunKills - propertyRerunPasses
            let rest = unsettled > 0 ? "; \(unsettled) timed out or didn't build, which settles nothing" : ""
            sentences.append(
                "The property tests ran again on their own for \(kills) only examples were recorded making: a "
                    + "property failed too for \(propertyRerunKills), which count as by both, and every property "
                    + "passed for \(propertyRerunPasses)\(rest)."
            )
        }
        if killedNamingNoTest > 0 {
            let (these, name, counts) = killedNamingNoTest == 1
                ? ("1 more killed mutant", "names", "it counts")
                : ("\(killedNamingNoTest) more killed mutants", "name", "they count")
            sentences.append(
                "\(these)\(share(killedNamingNoTest)) \(name) no failed test, as a crash may not, so \(counts) as "
                    + "neither."
            )
        }
        if countsAreBounds {
            let incomplete = incompleteExampleOnlyKills + incompletePropertyOnlyKills
            let (these, their) = incomplete == 1 ? ("1 of the kills by one kind", "its") : (
                "\(incomplete) of the kills by one kind", "their"
            )
            sentences.append(
                "\(these) stopped at \(their) first failed test or time limit, or named more than "
                    + "\(FailedTestLine.killedByLimit) tests, so a test of the other kind may have failed too: the "
                    + "count by both is a lower bound, and the counts by one kind alone may be high. "
                    + "stopAtFirstFailure: false records every failed test, at the cost of a longer run."
            )
        }
        return sentences
    }

    /// Says the list stops short of every property that failed, when it does, or that none did.
    var shownPropertiesSentence: String? {
        if distinctProperties == 0 {
            return "No property test was recorded failing for a killed mutant."
        }
        guard distinctProperties > properties.count else { return nil }
        return "These are \(properties.count) of the \(distinctProperties) property tests that failed. "
            + "The JSON report lists each mutant's tests."
    }
}
