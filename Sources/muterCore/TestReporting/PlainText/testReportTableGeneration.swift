import Foundation
import Rainbow

func generateAppliedMutationOperatorsCLITable(
    from fileReports: [MuterTestReport.FileReport],
    coloringFunction: ([CLITable.Row]) -> [CLITable.Row] = applyMutationTestResultsColor
) -> CLITable {
    var appliedMutations = [CLITable.Row]()
    var fileNames = [CLITable.Row]()
    var mutationTestResults = [CLITable.Row]()
    var killedBy = [CLITable.Row]()

    for (fileName, appliedMutation, testResult, killers) in fileReports.flatMap(operatorsToTableRows) {
        fileNames.append(fileName)
        appliedMutations.append(appliedMutation)
        mutationTestResults.append(testResult)
        killedBy.append(killers)
    }

    mutationTestResults = coloringFunction(mutationTestResults)

    let columns = [
        CLITable.Column(title: "File", rows: fileNames),
        CLITable.Column(title: "Applied Mutation Operator", rows: appliedMutations),
        CLITable.Column(title: "Mutation Test Result", rows: mutationTestResults),
    ]
    // Only when some killed mutant recorded its tests, so a report without them is as it was.
    let killedByColumn = CLITable.Column(title: "Killed By", rows: killedBy)
    return CLITable(padding: 3, columns: fileReports.showsKillingTests ? columns + [killedByColumn] : columns)
}

private func operatorsToTableRows(fileReport: MuterTestReport.FileReport) -> [(
    CLITable.Row,
    CLITable.Row,
    CLITable.Row,
    CLITable.Row
)] {
    fileReport.appliedOperators.map {
        (
            CLITable.Row(value: "\(fileReport.fileName):\($0.mutationPoint.position.line)"),
            CLITable.Row(value: $0.mutationPoint.mutationOperatorId.rawValue),
            CLITable.Row(value: $0.testSuiteOutcome.asMutationTestOutcome),
            CLITable.Row(value: $0.killedByCell)
        )
    }
}

extension MuterTestReport.AppliedMutationOperator {
    /// How many characters of a test's name the plain report's tables show, and the HTML report's Killed By column.
    static let killedByNameLimit = 60

    /// `name` as those tables show it: cut at `killedByNameLimit` characters, the last of them "…".
    static func shownName(_ name: String) -> String {
        name.count > killedByNameLimit ? String(name.prefix(killedByNameLimit - 1)) + "…" : name
    }

    /// The tests recorded failing for a mutant they killed, by a failed test or a crash. nil for any other mutant: a
    /// timeout's run records an empty list.
    var killedByTests: MutationTestOutcome.KillingTests? {
        [TestSuiteOutcome.failed, .runtimeError].contains(testSuiteOutcome) ? killingTests : nil
    }

    /// What the plain and HTML reports' Killed By column shows: the first test recorded failing, its name cut at 60
    /// characters with "…", then how many more failed, and whether only suspect tests did. Never empty: CLITable
    /// drops an empty line, which misaligns every row after it.
    var killedByCell: String {
        guard let killing = killedByTests else { return "-" }
        guard let first = killing.tests.first else { return "(none named)" }
        let more = killing.count > 1 ? " (+\(killing.count - 1))" : ""
        let suspectOnly = killedOnlyBySuspectTests == true ? " (suspect only)" : ""
        return Self.shownName(first.name) + more + suspectOnly
    }
}

extension [MuterTestReport.FileReport] {
    /// Whether some killed mutant recorded its tests, so the reports show a Killed By column.
    var showsKillingTests: Bool {
        contains { report in report.appliedOperators.contains { $0.killedByTests != nil } }
    }
}

/// The Killing Tests section's table: each test's name, cut as the Killed By column cuts it, the file its issues were
/// recorded in, and what it failed for.
func generateKillingTestsCLITable(from summary: KillingTestSummary) -> CLITable {
    let column = { (title: String, cell: (KillingTestSummary.Test) -> String) in
        CLITable.Column(title: title, rows: summary.tests.map { CLITable.Row(value: cell($0)) })
    }
    return CLITable(padding: 3, columns: [
        column("Test") { MuterTestReport.AppliedMutationOperator.shownName($0.name) },
        column("File") { $0.file ?? "-" },
        column("Mutants") { "\($0.mutants)" },
        column("Files") { "\($0.files)" },
        column("Only Recorded Failure Of") { "\($0.onlyRecordedFailureOf)" },
        column("Suspect") { $0.suspect ? "yes" : "-" },
    ])
}

func generateMutationScoresCLITable(
    from fileReports: [MuterTestReport.FileReport],
    coloringFunction: ([CLITable.Row]) -> [CLITable.Row] = applyMutationScoreColor
) -> CLITable {
    var fileNames = [CLITable.Row]()
    var numberOfInsertedMutants = [CLITable.Row]()
    var mutationScores = [CLITable.Row]()

    for fileReport in fileReports {
        fileNames.append(CLITable.Row(value: fileReport.fileName))
        numberOfInsertedMutants.append(CLITable.Row(value: "\(fileReport.appliedOperators.count)"))
        mutationScores.append(CLITable.Row(value: "\(fileReport.mutationScore)"))
    }

    mutationScores = coloringFunction(mutationScores)

    return CLITable(padding: 3, columns: [
        CLITable.Column(title: "File", rows: fileNames),
        CLITable.Column(title: "# of Introduced Mutants", rows: numberOfInsertedMutants),
        CLITable.Column(title: "Mutation Score", rows: mutationScores),
    ])
}

// MARK: - Coloring Functions

func applyMutationTestResultsColor(to rows: [CLITable.Row]) -> [CLITable.Row] {
    rows.map {
        let coloredValue = [
            TestSuiteOutcome.passed.asMutationTestOutcome,
            TestSuiteOutcome.buildError.asMutationTestOutcome,
        ].contains($0.value)
            ? $0.value.red
            : $0.value.green

        let coloredRow = CLITable.Row(value: coloredValue)
        return coloredRow
    }
}

func applyMutationScoreColor(to rows: [CLITable.Row]) -> [CLITable.Row] {
    rows.map {
        let coloredValue = coloredMutationScore(for: Int($0.value)!, appliedTo: $0.value)
        return CLITable.Row(value: coloredValue)
    }
}

func coloredMutationScore(for score: Int, appliedTo text: String) -> String {
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
