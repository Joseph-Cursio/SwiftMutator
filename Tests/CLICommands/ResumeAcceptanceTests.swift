@testable import muterCore
import XCTest

/// Runs the built `swift-mutator` on a two-file project whose test command is a shell script, stops a run partway with
/// a real SIGINT to its process group, which holds that SwiftMutator alone, and continues it with the command its
/// summary printed, run by a shell as it would be pasted. Every process a test starts is killed however the test ends,
/// every wait is bounded, and every file a test writes is in a temporary folder.
final class ResumeAcceptanceTests: XCTestCase {
    /// The project, and the processes a test starts on it.
    private let harness = ResumeHarness()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try harness.create()
    }

    override func tearDownWithError() throws {
        harness.cleanUp()
        try super.tearDownWithError()
    }

    func test_aStoppedRun_resumes_testingOnlyWhatIsLeft_andReportsLikeAFullRun() throws {
        let (resultsFile, continueCommand) = try harness.stopTheFirstSession(splittingWith: wordsAShellReads(in:))
        let ranBefore = harness.ranLines()
        try FileManager.default.removeItem(at: harness.hangMarker)

        let resumed = try harness.waitForEnd(of: harness.launch(commandLine: continueCommand))

        XCTAssertEqual(resumed.status, 0, resumed.standardError + resumed.standardOutput)
        // Standard output is a file, so a line per mutant in place of the bar, counting only the mutants left.
        let progress = resumed.standardOutput.components(separatedBy: "\n")
            .filter { $0.range(of: #"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] "#, options: .regularExpression) != nil }
            .map { $0.dropFirst(11).components(separatedBy: " | ")[0] }
        XCTAssertEqual(progress, ["0 of 2 (0%)", "1 of 2 (50%)", "2 of 2 (100%)"], resumed.standardOutput)
        XCTAssertFalse(resumed.standardOutput.contains("\u{1B}"), resumed.standardOutput)
        let lines = try harness.records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(4).first)
        XCTAssertEqual(header["session"] as? Int, 2)
        // Format 4, as its kills keep no log, so their lines have no `log`.
        XCTAssertEqual(header["formatVersion"] as? Int, 4)
        XCTAssertNil(header["project"], "the tree is recorded as what changed since session 1's")
        let delta = try XCTUnwrap(header["projectDelta"] as? [String: Any])
        let firstTree = try XCTUnwrap(lines.first?["project"] as? [String: Any])
        XCTAssertEqual(delta["baseTreeSHA256"] as? String, firstTree["treeSHA256"] as? String)
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
        XCTAssertEqual(header["mutantsToTest"] as? Int, 2)
        XCTAssertEqual(header["mutantsDiscovered"] as? Int, 4)
        // Only the Checks mutants, which the first session never finished, ran again, after a baseline of their own.
        let tested = lines.dropFirst(4)
            .filter { $0["kind"] as? String == "mutant" }
            .compactMap { $0["switchID"] as? String }
        XCTAssertEqual(tested.count, 2, "\(tested)")
        XCTAssertEqual(Set(tested).count, tested.count, "\(tested)")
        XCTAssertTrue(tested.allSatisfy { $0.hasPrefix("Checks_") }, "\(tested)")
        XCTAssertEqual(Array(harness.ranLines().dropFirst(ranBefore.count)), ["baseline"] + tested)
        XCTAssertEqual(ranBefore.last, tested.first, "the first session hung in the first Checks mutant")

        try assertTheReportsAreAFullRuns(resultsFile: resultsFile)
        XCTAssertEqual(harness.workerClones(), [], "no worker clone is left")
    }

    /// That the run's JSON report, and the reports `swift-mutator report` rebuilds from its results file and from the
    /// resumed session's log folder, are a full run's.
    private func assertTheReportsAreAFullRuns(resultsFile: URL) throws {
        XCTAssertEqual(try harness.outcomes(inJSONReportAt: harness.report), ["failed", "failed", "passed", "passed"])
        XCTAssertEqual(
            try harness.killingTestNames(inJSONReportAt: harness.report),
            [["check()"], ["check()"], nil, nil]
        )
        let rebuilt = try harness.waitForEnd(of: harness.launch(["report", resultsFile.path, "-f", "json"]))
        XCTAssertEqual(rebuilt.status, 0, rebuilt.standardError)
        let sessions = "Of these, 2 were tested in the last session, session 2, and 2 in session 1."
        XCTAssertTrue(rebuilt.standardError.contains(sessions), rebuilt.standardError)
        let rebuiltReport = try JSONSerialization.jsonObject(
            with: Data(rebuilt.standardOutput.utf8)
        ) as? [String: AnyHashable]
        XCTAssertEqual(rebuiltReport, try harness.parsedJSON(at: harness.report))
        // The resumed session's own log folder holds no results file, but a note naming the file, which `report`
        // follows.
        let resumedFolder = try XCTUnwrap(harness.resumedSessionsFolders(besides: resultsFile).first)
        XCTAssertEqual(try harness.notedFile(in: resumedFolder), resultsFile.resolvingSymlinksInPath().path)
        let fromFolder = try harness.waitForEnd(of: harness.launch(["report", resumedFolder.path, "-f", "json"]))
        XCTAssertEqual(fromFolder.status, 0, fromFolder.standardError)
        let folderReport = try JSONSerialization.jsonObject(
            with: Data(fromFolder.standardOutput.utf8)
        ) as? [String: AnyHashable]
        XCTAssertEqual(folderReport, try harness.parsedJSON(at: harness.report))
    }

    func test_aResumeOfAFileInUse_isRefused_beforeTheLiveRunsCopyIsTouched() throws {
        try harness.createHangMarker()
        let first = try harness.launch(harness.firstSessionArguments)
        try harness.waitUntilHanging(first)
        let resultsFile = try harness.onlyResultsFile()

        let refused = try harness.waitForEnd(
            of: harness.launch(harness.firstSessionArguments + ["--resume", resultsFile.path])
        )

        XCTAssertEqual(refused.status, 6, refused.standardError + refused.standardOutput)
        // The live run records itself as the lock's holder.
        XCTAssertTrue(
            refused.standardOutput.contains(
                "another SwiftMutator run, process \(first.process.processIdentifier) on "
            ),
            refused.standardOutput
        )
        XCTAssertTrue(refused.standardOutput.contains("holds its lock"), refused.standardOutput)
        XCTAssertTrue(first.process.isRunning, "the refused resume stopped the run it found holding the file")
        harness.recordMarkers()
        XCTAssertEqual(harness.sleepers.filter(harness.isGone).sorted(), [], "the hanging test process ended")
        XCTAssertTrue(harness.exists("project_mutated.active-mutant"), "the live run's files were touched")

        harness.signalGroup(of: first, SIGINT)

        harness.assertDied(first, by: SIGINT)
        harness.assertNoTestProcessIsLeft()
    }

    func test_aRunOfAProjectInUse_isRefused_withItsOwnStatus() throws {
        try harness.createHangMarker()
        let first = try harness.launch(harness.firstSessionArguments)
        try harness.waitUntilHanging(first)

        let refused = try harness.waitForEnd(of: harness.launch(harness.firstSessionArguments))

        XCTAssertEqual(refused.status, 6, refused.standardError + refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("SwiftMutator won't start"), refused.standardOutput)
        XCTAssertTrue(
            refused.standardOutput.contains("(process \(first.process.processIdentifier)) is using"),
            refused.standardOutput
        )
        XCTAssertFalse(refused.standardOutput.contains("please open an issue"), refused.standardOutput)
        XCTAssertTrue(first.process.isRunning, "the refused run stopped the run it found holding the project")
        XCTAssertTrue(harness.exists("project_mutated.active-mutant"), "the live run's files were touched")

        harness.signalGroup(of: first, SIGINT)

        harness.assertDied(first, by: SIGINT)
        harness.assertNoTestProcessIsLeft()
    }

    // An older SwiftMutator runs in `project_mutated` and locks `project_mutated.lock`, the file this one locks for
    // `project_mutated.noindex`. So this one refuses to start, and never removes the copy that run tests in, though it
    // removes such a copy as a leftover once no run holds the lock.
    func test_aRunWhileAnOlderSwiftMutatorRunsInTheOldNamedCopy_isRefused_andLeavesThatCopy() throws {
        let olderCopy = harness.root.appendingPathComponent("project_mutated", isDirectory: true)
        let olderMarker = olderCopy.appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: olderCopy, withIntermediateDirectories: true)
        try "".write(to: olderMarker, atomically: true, encoding: .utf8)
        let older = try MutatedProjectLock.Locker { nil }.lock(olderCopy)

        let refused = try harness.waitForEnd(of: harness.launch(harness.firstSessionArguments))

        XCTAssertEqual(refused.status, 6, refused.standardError + refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("SwiftMutator won't start"), refused.standardOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderMarker.path), "the older run's copy was touched")
        XCTAssertFalse(harness.exists("project_mutated.noindex"), "the project was copied")
        older.release()
    }

    func test_aChangedProjectFile_refusesBeforeTheCopy_andResumeIgnoringLetsItThrough() throws {
        let (resultsFile, continueCommand) = try harness.stopTheFirstSession(splittingWith: wordsAShellReads(in:))
        try FileManager.default.removeItem(at: harness.hangMarker)
        try "Not read by any test.\n".write(
            to: harness.project.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let copyMarker = harness.root.appendingPathComponent("project_mutated.noindex/left-by-the-test")
        try "".write(to: copyMarker, atomically: true, encoding: .utf8)

        let refused = try harness.waitForEnd(of: harness.launch(commandLine: continueCommand))

        XCTAssertEqual(refused.status, 5, refused.standardError + refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("notes.txt (added)"), refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("--resume-ignoring 'notes.txt'"), refused.standardOutput)
        XCTAssertTrue(refused.standardOutput.contains("Nothing was copied or removed."), refused.standardOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyMarker.path), "the last run's copy was touched")
        XCTAssertEqual(
            try harness.kinds(in: resultsFile),
            ["header", "mutant", "mutant", "end"],
            "the refusal wrote a line"
        )

        let waived = try harness.waitForEnd(
            of: harness.launch(commandLine: continueCommand + " --resume-ignoring notes.txt")
        )

        XCTAssertEqual(waived.status, 0, waived.standardError + waived.standardOutput)
        let lines = try harness.records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "end", "header", "mutant", "mutant", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(4).first)
        XCTAssertEqual(header["waived"] as? [String], ["notes.txt"])
        XCTAssertEqual(header["mutantsReused"] as? Int, 2)
    }

    func test_aFinishedRun_resumes_asANoOp_withoutABaseline() throws {
        let first = try harness.waitForEnd(of: harness.launch(harness.firstSessionArguments))
        XCTAssertEqual(first.status, 0, first.standardError + first.standardOutput)
        let resultsFile = try harness.onlyResultsFile()
        let ranBefore = harness.ranLines()
        XCTAssertEqual(ranBefore.count, 5, "the baseline and 4 mutants: \(ranBefore)")
        // The resume writes the report to the same path, so only one it wrote itself can be checked.
        try FileManager.default.removeItem(at: harness.report)

        let resumed = try harness.waitForEnd(
            of: harness.launch(harness.firstSessionArguments + ["--resume", resultsFile.path])
        )

        XCTAssertEqual(resumed.status, 0, resumed.standardError + resumed.standardOutput)
        XCTAssertTrue(resumed.standardOutput.contains("nothing is left to test"), resumed.standardOutput)
        XCTAssertEqual(harness.ranLines(), ranBefore, "neither a baseline nor a mutant ran")
        let lines = try harness.records(in: resultsFile)
        XCTAssertEqual(
            lines.map { $0["kind"] as? String },
            ["header", "mutant", "mutant", "mutant", "mutant", "end", "header", "end"]
        )
        let header = try XCTUnwrap(lines.dropFirst(6).first)
        XCTAssertEqual(header["session"] as? Int, 2)
        XCTAssertEqual(header["mutantsToTest"] as? Int, 0)
        XCTAssertEqual(header["mutantsReused"] as? Int, 4)
        XCTAssertEqual(header["workers"] as? Int, 0)
        XCTAssertEqual(lines.last?["reason"] as? String, "finished")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.report.path), "the resume wrote no report")
        XCTAssertEqual(try harness.outcomes(inJSONReportAt: harness.report), ["failed", "failed", "passed", "passed"])
        // Every mutant was kept from the first session, the Checks kills with the test their lines name.
        XCTAssertEqual(
            try harness.killingTestNames(inJSONReportAt: harness.report),
            [["check()"], ["check()"], nil, nil]
        )
        // It kept no log, but the note naming the file keeps its folder, beside the run's marker.
        let resumedFolders = harness.resumedSessionsFolders(besides: resultsFile)
        XCTAssertEqual(resumedFolders.count, 1, "\(resumedFolders)")
        let resumedFolder = try XCTUnwrap(resumedFolders.first)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: resumedFolder.path)),
            ["resumed session.txt", ".swiftmutator-run"]
        )
        XCTAssertEqual(try harness.notedFile(in: resumedFolder), resultsFile.resolvingSymlinksInPath().path)
    }
}
