@testable import muterCore
import XCTest

extension BaselineMatchesTests {
    typealias Tested = BaselineMatches.TestedMutant

    func key(
        _ line: Int,
        column: Int = 17,
        path: String = "Sources/Rules.swift",
        operator id: MutationOperator.Id = .ror,
        occurrence: Int = 0
    ) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: id, line: line, column: column, occurrence: occurrence)
    }

    func entry(
        _ key: MutantKey,
        _ outcome: BaselineSurvivor.Outcome = .survived,
        before: String = "<",
        after: String = "<=",
        line: String? = "if count < limit {"
    ) -> BaselineSurvivor {
        BaselineSurvivor(mutant: key, outcome: outcome, before: before, after: after, line: line)
    }

    func tested(
        _ key: MutantKey,
        _ kind: BaselineMatches.MutantKind = .survivor(.survived),
        before: String = "<",
        after: String = "<=",
        line: String? = "if count < limit {"
    ) -> Tested {
        Tested(key: key, kind: kind, before: before, after: after, line: line)
    }

    /// A tested mutant whose line was, or wasn't, read, whatever `line` says.
    func tested(
        _ key: MutantKey,
        before: String,
        after: String,
        line: String?,
        lineUnread: Bool
    ) -> Tested {
        Tested(key: key, kind: .survivor(.survived), before: before, after: after, line: line, lineUnread: lineUnread)
    }
}
