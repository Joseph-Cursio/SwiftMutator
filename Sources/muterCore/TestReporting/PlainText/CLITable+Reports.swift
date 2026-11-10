import Foundation
import Rainbow

/// The plain report's tables, and the colors of their cells.
extension CLITable {
    /// The Applied Mutation Operators table: each mutant's place, operator and result, colored by
    /// `coloringFunction`, with a Killed By, Reused and Duration column when some mutant has one.
    static func appliedMutationOperators(
        from fileReports: [FileReport],
        coloringFunction: ([Row]) -> [Row] = applyMutationTestResultsColor
    ) -> Self {
        let operators = fileReports.flatMap { report in
            report.appliedOperators.map { (relativePath: report.relativePath, appliedOperator: $0) }
        }
        let mutants = operators.map(\.appliedOperator)
        let fileNames = operators.map { mutant in
            Row(value: MuterTestReport.place(mutant.appliedOperator, in: mutant.relativePath))
        }
        let appliedMutations = mutants.map { Row(value: $0.mutationPoint.mutationOperatorId.rawValue) }
        let mutationTestResults = coloringFunction(mutants.map { Row(value: $0.outcomeWords) })
        let killedBy = mutants.map { Row(value: $0.killedByCell) }
        let reused = mutants.map { Row(value: $0.reusedCell) }
        let durations = mutants.map { Row(value: $0.durationCell) }

        let columns = [
            Column(title: "File", rows: fileNames),
            Column(title: "Applied Mutation Operator", rows: appliedMutations),
            Column(title: "Mutation Test Result", rows: mutationTestResults),
        ]
        // Only when some killed mutant recorded its tests, so a report without them is as it was.
        let killedByColumn = Column(title: "Killed By", rows: killedBy)
        // Only when some result was reused from an earlier run, so a report without any is as it was.
        let reusedColumn = Column(title: "Reused", rows: reused)
        // Only when some mutant's duration is known.
        let durationColumn = Column(title: "Duration", rows: durations)
        return Self(
            padding: 3,
            columns: columns
                + (fileReports.showsKillingTests ? [killedByColumn] : [])
                + (fileReports.showsReuse ? [reusedColumn] : [])
                + (fileReports.showsDurations ? [durationColumn] : [])
        )
    }

    /// The Killing Tests section's table: each test's name, cut as the Killed By column cuts it, the file its issues
    /// were recorded in, and what it failed for.
    static func killingTests(from summary: KillingTestSummary) -> Self {
        let column = { (title: String, cell: (KillingTestSummary.Test) -> String) in
            Column(title: title, rows: summary.tests.map { Row(value: cell($0)) })
        }
        return Self(padding: 3, columns: [
            column("Test") { AppliedMutationOperator.shownName($0.name) },
            column("File") { $0.file ?? "-" },
            column("Mutants") { "\($0.mutants)" },
            column("Files") { "\($0.files)" },
            column("Only Recorded Failure Of") { "\($0.onlyRecordedFailureOf)" },
            column("Suspect") { $0.suspectCell },
        ])
    }

    /// The Examples and Properties section's table: each property test's name, cut as the Killed By column cuts it,
    /// the file its issues were recorded in, and the kills it made.
    static func propertyKills(from summary: PropertyKillSummary) -> Self {
        let column = { (title: String, cell: (PropertyKillSummary.Property) -> String) in
            Column(title: title, rows: summary.properties.map { Row(value: cell($0)) })
        }
        return Self(padding: 3, columns: [
            column("Property") { AppliedMutationOperator.shownName($0.name) },
            column("File") { $0.file ?? "-" },
            column("Mutants") { "\($0.mutants)" },
            column("Only Recorded Killer Of") { "\($0.onlyRecordedKillerOf)" },
        ])
    }

    /// The Mutation Test Scores table: each file's path, mutant count and score, colored by `coloringFunction`.
    static func mutationScores(
        from fileReports: [FileReport],
        coloringFunction: ([Row]) -> [Row] = applyMutationScoreColor
    ) -> Self {
        var fileNames = [Row]()
        var numberOfInsertedMutants = [Row]()
        var mutationScores = [Row]()

        for fileReport in fileReports {
            fileNames.append(Row(value: fileReport.relativePath))
            numberOfInsertedMutants.append(Row(value: "\(fileReport.appliedOperators.count)"))
            mutationScores.append(Row(value: "\(fileReport.mutationScore)"))
        }

        mutationScores = coloringFunction(mutationScores)

        return Self(padding: 3, columns: [
            Column(title: "File", rows: fileNames),
            Column(title: "# of Introduced Mutants", rows: numberOfInsertedMutants),
            Column(title: "Mutation Score", rows: mutationScores),
        ])
    }

    /// `rows` of mutation test results, red for a mutant not killed, green for one killed.
    static func applyMutationTestResultsColor(to rows: [Row]) -> [Row] {
        rows.map {
            let coloredValue = [
                TestSuiteOutcome.passed.asMutationTestOutcome,
                TestSuiteOutcome.buildError.asMutationTestOutcome,
                AppliedMutationOperator.notCoveredWords,
            ].contains($0.value)
                ? $0.value.red
                : $0.value.green

            return Row(value: coloredValue)
        }
    }

    /// `rows` of mutation scores, each colored as `coloredMutationScore(for:appliedTo:)` colors it.
    static func applyMutationScoreColor(to rows: [Row]) -> [Row] {
        rows.map {
            guard let score = Int($0.value) else { return $0 }
            return Row(value: coloredMutationScore(for: score, appliedTo: $0.value))
        }
    }

    /// `text` colored for `score`: red up to 25, yellow up to 50, light green up to 75, then green.
    static func coloredMutationScore(for score: Int, appliedTo text: String) -> String {
        switch score {
        case 0 ... 25:
            return text.red

        case 26 ... 50:
            return text.yellow

        case 51 ... 75:
            return text.lightGreen

        default:
            return text.green
        }
    }
}
