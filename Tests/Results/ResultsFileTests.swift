@testable import muterCore
import XCTest

final class ResultsFileTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    func test_create_namesItResultsJSONL() throws {
        let file = try ResultsFile.Opener().create(in: directory)

        XCTAssertEqual(file.path, "\(directory)/results.jsonl")
        XCTAssertEqual(try contents(of: file.path), Data())
    }

    func test_create_neverReplacesAnExistingFile_butTakesTheNextName() throws {
        let earlier = "\(directory)/results.jsonl"
        try Data("an earlier run's results\n".utf8).write(to: URL(fileURLWithPath: earlier))

        let second = try ResultsFile.Opener().create(in: directory)
        second.close()
        let third = try ResultsFile.Opener().create(in: directory)

        XCTAssertEqual(second.path, "\(directory)/results-2.jsonl")
        XCTAssertEqual(third.path, "\(directory)/results-3.jsonl")
        XCTAssertEqual(try contents(of: earlier), Data("an earlier run's results\n".utf8))
    }

    func test_create_givesUpAfterResults99() throws {
        for number in 1...99 {
            let name = number == 1 ? "results.jsonl" : "results-\(number).jsonl"
            try Data().write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
        }

        XCTAssertThrowsError(try ResultsFile.Opener().create(in: directory)) { error in
            XCTAssertEqual(
                error as? ResultsFileError,
                .cannotOpen(path: "\(directory)/results-99.jsonl", errno: EEXIST)
            )
        }
    }

    func test_create_inAFolderThatIsMissing_saysWhy() {
        XCTAssertThrowsError(try ResultsFile.Opener().create(in: "\(directory)/missing")) { error in
            XCTAssertEqual(
                error as? ResultsFileError,
                .cannotOpen(path: "\(directory)/missing/results.jsonl", errno: ENOENT)
            )
        }
    }

    func test_isResultsFileName_matchesEveryNameCreateGives_andNothingElse() throws {
        var names: Set<String> = []
        for _ in 1...99 {
            let file = try ResultsFile.Opener().create(in: directory)
            file.close()
            let name = file.path.lastPathComponent
            names.insert(name)
            XCTAssertTrue(ResultsFile.isResultsFileName(name), name)
        }
        XCTAssertEqual(names.count, 99)

        let others = [
            "results-1.jsonl", "results-100.jsonl", "results-02.jsonl", "results-.jsonl", "Results.jsonl",
            "results.json", "results.jsonl.bak", "results.jsonl.partial", "my results.jsonl", "",
        ]
        for name in others {
            XCTAssertFalse(ResultsFile.isResultsFileName(name), name)
        }
    }

    func test_find_aFile_isItself() throws {
        let file = "\(directory)/kept from an earlier run.jsonl"
        try Data().write(to: URL(fileURLWithPath: file))

        XCTAssertEqual(try ResultsFile.find(at: file, using: FileManager.default), file)
    }

    func test_find_aFolderWithOneResultsFile_givesIt() throws {
        for name in ["results.jsonl", "results-2.jsonl"] {
            let folder = try makeLogFolder(holding: [name, "baseline run.log", "Checks_RemoveSideEffects_3_5_42.log"])

            XCTAssertEqual(try ResultsFile.find(at: folder, using: FileManager.default), "\(folder)/\(name)")
            XCTAssertEqual(try ResultsFile.find(at: folder + "/", using: FileManager.default), "\(folder)/\(name)")
        }
    }

    func test_find_aFolderWithAHoldersRecord_givesTheResultsFile() throws {
        let folder = try makeLogFolder(holding: ["results.jsonl", ".results.jsonl.holder"])

        XCTAssertEqual(try ResultsFile.find(at: folder, using: FileManager.default), "\(folder)/results.jsonl")
    }

    func test_find_aFolderWithSeveral_isRefused_namingThemInOrder() throws {
        let folder = try makeLogFolder(
            holding: ["results-10.jsonl", "results.jsonl", "baseline run.log", "results-2.jsonl"]
        )

        XCTAssertThrowsError(try ResultsFile.find(at: folder, using: FileManager.default)) { error in
            XCTAssertEqual(
                error as? ResultsFileError,
                .severalResultsFiles(folder: folder, names: ["results.jsonl", "results-2.jsonl", "results-10.jsonl"])
            )
        }
    }

    func test_find_aFolderWithNone_isRefused() throws {
        let folder = try makeLogFolder(holding: ["baseline run.log", "results.json", "results-100.jsonl"])

        XCTAssertThrowsError(try ResultsFile.find(at: folder, using: FileManager.default)) { error in
            XCTAssertEqual(error as? ResultsFileError, .noResultsFile(folder: folder))
        }
    }

    func test_find_aMissingPath_isLeftForReadingToRefuse() throws {
        let missing = "\(directory)/missing/results.jsonl"

        XCTAssertEqual(try ResultsFile.find(at: missing, using: FileManager.default), missing)
    }

    // A glob for a run's results files, such as `*.jsonl`, `results*` or `*/results*`, never finds the note.
    func test_theNotesName_isNotAResultsFileName_andDoesntStartWithOne() {
        XCTAssertFalse(ResultsFile.isResultsFileName(ResultsFile.noteFileName))
        XCTAssertFalse(ResultsFile.noteFileName.hasPrefix("results"))
        XCTAssertNotEqual(ResultsFile.noteFileName.pathExtension, "jsonl")
    }

    func test_find_aResumedSessionsFolder_givesTheFileItsNoteNames() throws {
        let first = try makeLogFolder(holding: ["results.jsonl", "baseline run.log"])
        let resumed = try makeLogFolder(holding: ["baseline run.log"])
        try writeNote(pointingTo: "\(first)/results.jsonl", session: 2, in: resumed)

        let located = try ResultsFile.locate(at: resumed, using: FileManager.default)

        XCTAssertEqual(located.path, "\(first)/results.jsonl")
        XCTAssertTrue(located.isNoted)
        XCTAssertEqual(try ResultsFile.find(at: resumed + "/", using: FileManager.default), "\(first)/results.jsonl")
        XCTAssertFalse(try ResultsFile.locate(at: first, using: FileManager.default).isNoted)
    }

    // Once the first session's folder is removed, reading the file refuses it, naming the file rather than the folder.
    func test_find_aNoteNamingAMissingFile_isLeftForReadingToRefuse() throws {
        let missing = "\(directory)/removed/results-2.jsonl"
        let resumed = try makeLogFolder(holding: [])
        try writeNote(pointingTo: missing, session: 2, in: resumed)

        XCTAssertEqual(try ResultsFile.find(at: resumed, using: FileManager.default), missing)
    }

    // Only an absolute path to a file with a results file's name, on the first line, is followed.
    func test_find_aNoteWithoutAResultsFilesPath_isRefusedAsNoResultsFile() throws {
        let notes = [
            "results.jsonl\n",
            "\(directory)/notes.txt\n",
            "\(directory)/\n",
            "\nThe first line is empty.\n\(directory)/results.jsonl\n",
            "",
        ]
        for note in notes {
            let resumed = try makeLogFolder(holding: [])
            try Data(note.utf8).write(to: URL(fileURLWithPath: "\(resumed)/\(ResultsFile.noteFileName)"))

            XCTAssertThrowsError(try ResultsFile.find(at: resumed, using: FileManager.default), note) { error in
                XCTAssertEqual(error as? ResultsFileError, .noResultsFile(folder: resumed), note)
            }
        }
    }

    func test_find_aFolderWithAResultsFileAndANote_givesTheResultsFile() throws {
        let folder = try makeLogFolder(holding: ["results.jsonl"])
        try writeNote(pointingTo: "\(directory)/elsewhere/results.jsonl", session: 2, in: folder)

        let located = try ResultsFile.locate(at: folder, using: FileManager.default)

        XCTAssertEqual(located.path, "\(folder)/results.jsonl")
        XCTAssertFalse(located.isNoted)
    }

    func test_theNote_namesTheFileOnItsFirstLine_thenSaysWhatTheFolderIs() {
        XCTAssertEqual(
            ResultsFile.note(pointingTo: "/logs/Oct 6, 2026 at 9:12 AM/results.jsonl", session: 3),
            """
            /logs/Oct 6, 2026 at 9:12 AM/results.jsonl

            This folder holds the logs of session 3 of a resumed run. The run's results are in the results file \
            above, in the first session's log folder. Give that file, or this folder, to swift-mutator report, or to \
            swift-mutator run --resume or --reuse.

            """
        )
    }

    func test_errorsSayWhatHappened() {
        XCTAssertEqual(
            ResultsFileError.cannotOpen(path: "/logs/results.jsonl", errno: ENOENT).description,
            "can't open /logs/results.jsonl: No such file or directory"
        )
        XCTAssertEqual(
            ResultsFileError.inUse(path: "/logs/results.jsonl", holder: nil).description,
            "/logs/results.jsonl is in use by another SwiftMutator run"
        )
        let holder = LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "studio.local")
        XCTAssertEqual(
            ResultsFileError.inUse(path: "/logs/results.jsonl", holder: .running(holder)).description,
            "/logs/results.jsonl is in use by another SwiftMutator run (process 81234 on studio.local)"
        )
        XCTAssertEqual(
            ResultsFileError.inUse(path: "/logs/results.jsonl", holder: .unchecked(holder)).description,
            "/logs/results.jsonl is in use by another SwiftMutator run (process 81234 on studio.local, by its record, "
                + "which this host can't check)"
        )
        XCTAssertEqual(
            ResultsFileError.cannotWrite(path: "/logs/results.jsonl", errno: ENOSPC).description,
            "can't write to /logs/results.jsonl: No space left on device"
        )
        XCTAssertEqual(
            ResultsFileError.notAResultsFile(path: "/logs/notes.txt").description,
            "/logs/notes.txt isn't a SwiftMutator results file: it has no header line"
        )
        XCTAssertEqual(
            ResultsFileError.newerFormat(path: "/logs/results.jsonl", version: 3).description,
            "/logs/results.jsonl is in results format 3, which only a newer SwiftMutator can read"
        )
        XCTAssertEqual(
            ResultsFileError.noResultsFile(folder: "/logs/run").description,
            "/logs/run holds no results file (results.jsonl)"
        )
        XCTAssertEqual(
            ResultsFileError.severalResultsFiles(folder: "/logs/run", names: ["results.jsonl", "results-2.jsonl"])
                .description,
            "/logs/run holds 2 results files, one for each run that started in that minute: "
                + "results.jsonl, results-2.jsonl. Pass the one you want."
        )
    }
}
