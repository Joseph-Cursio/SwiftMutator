import Foundation

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
