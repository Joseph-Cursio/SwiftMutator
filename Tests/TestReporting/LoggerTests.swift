import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

final class LoggerTests: MuterTestCase {
    let sut = Logger()

    func test_printer() throws {
        try logTheRunUpToItsMutants()
        sut.mutationTestingStarted()
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                timePerBuildTestCycle: 300,
                remainingMutationPointsCount: 1
            )
        )
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                mutationPoint: .make()
            )
        )
        sut.testPlanFileCreated(
            TestPlanCreated(
                path: "/path/to/test-plan",
                mutatedProject: "../project_mutated",
                mutants: 12,
                files: 3,
                operators: nil
            )
        )
        sut.configurationFileCreated(atPath: "/path/to/config-file")
        sut.muterMutationTestPlanLoaded()
        sut.mutationTestingFinished(
            report: "... muter report ... ",
            reportPath: "/path/to/report",
            isExportingReport: true,
            didSaveReport: true,
            scoreLine: "Mutation score: 83% (98 killed, 15 survived, 4 timed out)",
            suspectWarning: nil
        )

        AssertSnapshot(printer.linesPassed.joined(separator: "\n"))
    }

    /// Logs a run from its launch up to the mutants it discovered.
    private func logTheRunUpToItsMutants() throws {
        sut.launched()
        sut.updateCheckStarted()
        sut.updateCheckFinished(newVersion: "1.0.0")
        sut.projectCopyStarted()
        sut.projectCopyFinished(destinationPath: "/path/to/destination")
        sut.projectCoverageDiscoveryStarted()
        sut.projectCoverageDiscoveryFinished(failureReason: nil)
        sut.sourceFileDiscoveryStarted()
        sut.sourceFileDiscoveryFinished(
            sourceFileCandidates: ["file0.swift", "file1.swift", "file2.swift"],
            verbose: true
        )
        sut.mutationsDiscoveryStarted()
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()], verbose: true)
    }

    func makeSchemataMapping() throws -> SchemataMutationMapping {
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

        sut.mutationsDiscoveryFinished(mutations: mappings, verbose: true)

        XCTAssertTrue(
            printer.linesPassed.contains("main.swift (2 mutants)".bold),
            "\(printer.linesPassed)"
        )
    }

    /// The percentage a drawn progress bar shows.
    func percent(_ draw: String) -> String {
        guard let sign = draw.range(of: "%") else { return "" }
        return String(draw[..<sign.lowerBound].reversed().prefix(while: \.isNumber).reversed()) + "%"
    }
}
