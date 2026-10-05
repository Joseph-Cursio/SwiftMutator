import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

final class LoggerTests: MuterTestCase {
    private let sut = Logger()

    func test_printer() throws {
        sut.launched()
        sut.updateCheckStarted()
        sut.updateCheckFinished(newVersion: "1.0.0")
        sut.projectCopyStarted()
        sut.projectCopyFinished(destinationPath: "/path/to/destination")
        sut.projectCoverageDiscoveryStarted()
        sut.projectCoverageDiscoveryFinished(success: true)
        sut.sourceFileDiscoveryStarted()
        sut.sourceFileDiscoveryFinished(sourceFileCandidates: ["file0.swift", "file1.swift", "file2.swift"])
        sut.mutationsDiscoveryStarted()
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()])
        sut.mutationTestingStarted()
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                timePerBuildTestCycle: 50,
                remainingMutationPointsCount: 5
            )
        )
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                mutationPoint: .make()
            )
        )
        sut.testPlanFileCreated(atPath: "/path/to/test-plan")
        sut.configurationFileCreated(atPath: "/path/to/config-file")
        sut.muterMutationTestPlanLoaded()
        sut.mutationTestingFinished(
            report: "... muter report ... ",
            reportPath: "/path/to/report",
            isExportingReport: true,
            didSaveReport: true
        )

        AssertSnapshot(printer.linesPassed.joined(separator: "\n"))
    }

    func test_print_writesThroughTheInjectedPrinter() {
        sut.print("a line")

        XCTAssertEqual(printer.linesPassed, ["a line"])
    }

    func test_projectCopySkippedVanishedFiles_listsUpToFivePaths() {
        sut.projectCopySkippedVanishedFiles((1 ... 7).map { "/p/f\($0).lock" })

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ Skipped 7 file(s) that disappeared while your project was being copied:
              /p/f1.lock
              /p/f2.lock
              /p/f3.lock
              /p/f4.lock
              /p/f5.lock
              … and 2 more
            """,
        ])
    }

    func test_resultsFileUnavailable_saysTheReportDoesntDependOnIt() {
        sut.resultsFileUnavailable(reason: "can't open /logs/results.jsonl: Permission denied")

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ SwiftMutator can't save each mutant's result as it goes: "
                + "can't open /logs/results.jsonl: Permission denied. The report at the end doesn't depend on it.",
        ])
    }

    // The progress bar's printer redraws it by moving the cursor up over its two lines, which would overwrite the
    // warning's last two rows. The empty lines take the redraw instead. After the bar's last redraw they aren't needed.
    func test_resultsFileUnavailable_whileTheProgressBarIsStillToRedraw_leavesItTwoEmptyLines() throws {
        let reason = "can't write to /logs/results.jsonl: No space left on device"
        let warning = "⚠️ SwiftMutator can't save each mutant's result as it goes: "
            + "\(reason). The report at the end doesn't depend on it."
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping(), makeSchemataMapping()])
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 50, remainingMutationPointsCount: 2)
        )

        var printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning, "", ""])

        // With two mutants, the first one's log redraws the bar for the last time.
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning])
    }

    func test_resultsFileCreated_andKept_nameTheFile() {
        sut.resultsFileCreated(atPath: "/logs/results.jsonl")
        sut.resultsFileKept(atPath: "/logs/results.jsonl")

        XCTAssertEqual(printer.linesPassed, [
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)",
            "💾 Each mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    func test_stopAtFirstFailureTurnedOff_saysWhy() {
        sut.stopAtFirstFailureTurnedOff(reason: "the test arguments retry failing tests")

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: "
                + "the test arguments retry failing tests",
        ])
    }

    private func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: .firstPosition,
                        snapshot: .null
                    ),
                ]
            )
        )
    }

    func test_mutationsDiscoveryFinished_countsFilesWithTheSameNameTogether() throws {
        let mappings = try ["/project/First/main.swift", "/project/Second/main.swift"].map { path in
            try SchemataMutationMapping.make(
                filePath: path,
                (source: "func bar() { }", schemata: [.make(filePath: path, position: .firstPosition)])
            )
        }

        sut.mutationsDiscoveryFinished(mutations: mappings)

        XCTAssertTrue(
            printer.linesPassed.contains("main.swift (2 mutants)".bold),
            "\(printer.linesPassed)"
        )
    }
}
