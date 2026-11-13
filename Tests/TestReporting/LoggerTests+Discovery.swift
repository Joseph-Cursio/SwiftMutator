@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    func test_print_writesThroughTheInjectedPrinter() {
        sut.print("a line")

        XCTAssertEqual(printer.linesPassed, ["a line"])
    }

    // Off a terminal, standard output is block-buffered, so a log file would get each line late, or not at all after a
    // crash, and after anything later on standard error. On a terminal it is flushed at each line anyway.
    func test_withoutATerminal_eachLineIsFlushedAsItIsPrinted() {
        let written = Locked<[String]>([])
        current.printer = { line in written.change { $0.append(line) } }
        current.flushStandardOut = { written.change { $0.append("(flushed)") } }

        current.standardOutIsATerminal = false
        sut.print("a line")
        sut.print("another")
        current.standardOutIsATerminal = true
        sut.print("on a terminal")

        XCTAssertEqual(written.value, ["a line", "(flushed)", "another", "(flushed)", "on a terminal"])
    }

    // The lines `tail -f` follows most: the first, and each mutant's.
    func test_withoutATerminal_eachProgressLine_isFlushed() {
        current.standardOutIsATerminal = false
        let written = Locked<[String]>([])
        current.printer = { line in written.change { $0.append(line) } }
        current.flushStandardOut = { written.change { $0.append("(flushed)") } }
        sut.resumePlanned(.make(reused: 0, toTest: 1, retestedBecause: [.notRecorded: 1]))
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 1)
        )
        XCTAssertEqual(written.value.suffix(2), ["[02:42:00] 0 of 1 (0%) | 1 min left", "(flushed)"])

        sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: .failed))

        XCTAssertEqual(written.value.last, "(flushed)")
        XCTAssertTrue(
            written.value.dropLast().last?.hasPrefix("[02:42:00] 1 of 1 (100%) | 1 killed | "),
            "\(written.value)"
        )
    }

    // Each file's name, then how many mutants each file with any has, take hundreds of lines on a large project: 830, a
    // fifth of the log of a run of SwiftProjectLint. So they're listed only with --verbose.
    func test_discovery_saysHowManyFilesAndMutants_andListsThemOnlyWhenVerbose() throws {
        sut.sourceFileDiscoveryFinished(sourceFileCandidates: ["/p/a.swift", "/p/b.swift"])
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()])
        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 2 Swift files",
            "✅ In total, SwiftMutator discovered 1 mutants in 1 files",
        ])

        let printedBefore = printer.linesPassed.count
        let verbose = Logger()
        verbose.sourceFileDiscoveryFinished(sourceFileCandidates: ["/p/a.swift", "/p/b.swift"], verbose: true)
        try verbose.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()], verbose: true)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [
            "✅ In total, SwiftMutator discovered 2 Swift files\n\n" + "a.swift\nb.swift".bold,
            "✅ In total, SwiftMutator discovered 1 mutants in 1 files\n",
            "path (1 mutants)".bold,
        ])
    }

    // SwiftPM's errors often end in a full stop, which isn't doubled.
    func test_packageSourceFilesUnavailable_saysWhyAndWhatDiscoveryDoesInstead() {
        sut.packageSourceFilesUnavailable(reason: "`swift package describe` failed for /p: error: invalid manifest.")

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ SwiftMutator couldn't tell which files the package's targets compile: `swift package describe` failed \
            for /p: error: invalid manifest.
            It looks at every Swift file in the project that isn't hidden or ignored instead, so a file no target \
            builds may get mutants no test can kill. \("exclude".bold) can leave such files out.
            """,
        ])
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
}
