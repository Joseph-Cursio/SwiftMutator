import ArgumentParser
@testable import muterCore
import XCTest

extension NewSurvivorsCheckTests {
    func key(_ line: Int, path: String = "Sources/X.swift") -> MutantKey {
        MutantKey(path: path, mutationOperatorId: .relationalBoundary, line: line, column: 17, occurrence: 0)
    }

    func baseline(_ survivors: [MutantKey], version: String = "0.1.0") -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: version,
            score: .init(killed: 0, scored: 0),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: survivors.map { BaselineSurvivor(mutant: $0, outcome: .survived, before: "<", after: "<=") }
        )
    }

    func outcome(_ mutants: [(MutantKey, TestSuiteOutcome)], mutant: String? = nil) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutants.map { key, outcome in
                .make(testSuiteOutcome: outcome, snapshot: .make(before: "<", after: "<="), key: key)
            },
            mutant: mutant
        )
    }

    func check(
        _ survivors: [MutantKey],
        against mutants: [(MutantKey, TestSuiteOutcome)],
        allowing allowed: Int = 0,
        version: String = "0.1.0",
        mutant: String? = nil,
        unless notChecked: NewSurvivorsCheck.NotChecked? = nil
    ) -> NewSurvivorsCheck {
        NewSurvivorsCheck(
            baseline: baseline(survivors),
            maxNewSurvivors: allowed,
            judging: outcome(mutants, mutant: mutant),
            version: version,
            unless: notChecked
        ) { _ in nil }
    }
}
