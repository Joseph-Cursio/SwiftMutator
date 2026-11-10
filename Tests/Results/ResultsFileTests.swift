@testable import muterCore
import XCTest

final class ResultsFileTests: XCTestCase {
    private var directory = ""
    private let header = ResultsHeader.make()
    private let mutant = MutantResult.make()
    private let end = ResultsEnd.make()
    /// The header a resumed session appends.
    private let nextHeader = ResultsHeader.make(formatVersion: ResultsCoding.resumedFormatVersion, session: 2)

    private var resultsPath: String {
        "\(directory)/results.jsonl"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
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
            let name = (file.path as NSString).lastPathComponent
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
        XCTAssertNotEqual((ResultsFile.noteFileName as NSString).pathExtension, "jsonl")
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

    func test_aLineIsOnDiskWhenAppendReturns() throws {
        let file = try ResultsFile.Opener().create(in: directory)

        XCTAssertTrue(file.append(header))

        XCTAssertEqual(try contents(of: file.path), try line(header))
        XCTAssertNil(file.writeError)
    }

    func test_eachAppendIsOneCompleteLine() throws {
        let file = try ResultsFile.Opener().create(in: directory)

        XCTAssertTrue(file.append(header))
        XCTAssertTrue(file.append(mutant))
        XCTAssertTrue(file.append(end))

        let lines = try contents(of: file.path).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last, Data())
        XCTAssertEqual(try ResultsCoding.decoder.decode(ResultsHeader.self, from: Data(lines[0])), header)
        XCTAssertEqual(try ResultsCoding.decoder.decode(MutantResult.self, from: Data(lines[1])), mutant)
        XCTAssertEqual(try ResultsCoding.decoder.decode(ResultsEnd.self, from: Data(lines[2])), end)
    }

    func test_eachLineIsWrittenThenSynchronized_beforeAppendReturns() throws {
        var calls: [String] = []
        let file = try makeFile(
            writeBytes: { descriptor, bytes, count in
                calls.append("write")
                return write(descriptor, bytes, count)
            },
            synchronize: { descriptor in
                calls.append("fsync")
                return fsync(descriptor)
            }
        )

        XCTAssertTrue(file.append(header))
        XCTAssertEqual(calls, ["write", "fsync"])
        XCTAssertTrue(file.append(mutant))
        XCTAssertEqual(calls, ["write", "fsync", "write", "fsync"])
    }

    // A reuse writes the results it keeps, thousands of them, together: one write and one sync, each a line of its own.
    func test_appendContentsOf_writesTheLinesTogether_andSynchronizesOnce() throws {
        var calls: [String] = []
        let file = try makeFile(
            writeBytes: { descriptor, bytes, count in
                calls.append("write")
                return write(descriptor, bytes, count)
            },
            synchronize: { descriptor in
                calls.append("fsync")
                return fsync(descriptor)
            }
        )
        let other = MutantResult.make(line: 80)

        XCTAssertTrue(file.append(contentsOf: [mutant, other]))

        XCTAssertEqual(calls, ["write", "fsync"])
        XCTAssertEqual(try contents(of: file.path), try line(mutant) + line(other))
        XCTAssertTrue(file.append(contentsOf: [any Encodable]()))
        XCTAssertEqual(calls, ["write", "fsync"], "nothing to write, so nothing is written")
    }

    // A resumed session's header and its `retired` line go together, so a run killed as it starts leaves both or
    // neither.
    func test_appendContentsOf_writesLinesOfDifferentKinds_inOneWrite() throws {
        var calls: [String] = []
        let file = try makeFile(
            writeBytes: { descriptor, bytes, count in
                calls.append("write")
                return write(descriptor, bytes, count)
            },
            synchronize: { descriptor in
                calls.append("fsync")
                return fsync(descriptor)
            }
        )
        let retired = ResultsRetired(session: 2, keys: [mutant.key])

        XCTAssertTrue(file.append(contentsOf: [nextHeader, retired]))

        XCTAssertEqual(calls, ["write", "fsync"])
        XCTAssertEqual(try contents(of: file.path), try line(nextHeader) + line(retired))
    }

    func test_aShortOrInterruptedWriteOrSync_isCompleted() throws {
        var writes = 0
        var syncs = 0
        let file = try makeFile(
            writeBytes: { descriptor, bytes, count in
                writes += 1
                switch writes {
                case 1: return write(descriptor, bytes, 5)
                case 2:
                    errno = EINTR
                    return -1
                default: return write(descriptor, bytes, count)
                }
            },
            synchronize: { descriptor in
                syncs += 1
                guard syncs > 1 else {
                    errno = EINTR
                    return -1
                }
                return fsync(descriptor)
            }
        )

        XCTAssertTrue(file.append(mutant))

        XCTAssertEqual(try contents(of: file.path), try line(mutant))
        XCTAssertEqual(writes, 3)
        XCTAssertEqual(syncs, 2)
        XCTAssertNil(file.writeError)
    }

    func test_afterAFailedWrite_nothingMoreIsWritten() throws {
        var writes = 0
        let file = try makeFile(writeBytes: { descriptor, bytes, count in
            writes += 1
            switch writes {
            case 1: return write(descriptor, bytes, count)
            case 2: return write(descriptor, bytes, 10)
            default:
                errno = ENOSPC
                return -1
            }
        })

        XCTAssertTrue(file.append(header))
        XCTAssertFalse(file.append(mutant))
        XCTAssertFalse(file.append(end))

        XCTAssertEqual(writes, 3, "the third append writes nothing")
        XCTAssertEqual(file.writeError as? ResultsFileError, .cannotWrite(path: file.path, errno: ENOSPC))
        XCTAssertEqual(try contents(of: file.path), try line(header) + line(mutant).prefix(10))
        let recorded = try RecordedResults.read(contents(of: file.path), path: file.path)
        XCTAssertEqual(recorded.headers, [header])
        XCTAssertTrue(recorded.endsWithCutOffLine)
    }

    func test_afterAFailedSync_nothingMoreIsWritten() throws {
        var writes = 0
        let file = try makeFile(
            writeBytes: { descriptor, bytes, count in
                writes += 1
                return write(descriptor, bytes, count)
            },
            synchronize: { _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertFalse(file.append(header))
        XCTAssertFalse(file.append(mutant))

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(file.writeError as? ResultsFileError, .cannotWrite(path: file.path, errno: EIO))
    }

    func test_afterClosing_nothingMoreIsWritten() throws {
        let file = try ResultsFile.Opener().create(in: directory)
        XCTAssertTrue(file.append(header))

        file.close()
        file.close()

        XCTAssertFalse(file.append(mutant))
        XCTAssertNil(file.writeError)
        XCTAssertEqual(try contents(of: file.path), try line(header))
    }

    func test_aSecondWriterIsRefusedWhileTheFirstHoldsTheLock() throws {
        let first = try ResultsFile.Opener().create(in: directory)
        let second = openForAppending(first.path)

        // A flock belongs to an open file, so a holder in this process holds it as another process would.
        let holder = try XCTUnwrap(LockHolder.current())

        XCTAssertThrowsError(try ResultsFile(descriptor: second, path: first.path)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: first.path, holder: .running(holder)))
        }
        XCTAssertEqual(fcntl(second, F_GETFD), -1, "the refused descriptor is closed")
        XCTAssertTrue(first.append(header))
    }

    // A record named for the file, but hidden, so no glob for results files finds it.
    func test_theHoldersRecord_isAHiddenFileBesideTheResultsFile() {
        XCTAssertEqual(ResultsFile.holderPath(for: "/logs/run/results.jsonl"), "/logs/run/.results.jsonl.holder")
        XCTAssertEqual(ResultsFile.holderPath(for: "/logs/run/results-2.jsonl"), "/logs/run/.results-2.jsonl.holder")
    }

    // A killed run leaves a record, which may be longer than this one: what is left of it must not follow this one.
    func test_create_andOpenForResume_recordTheHolder_overAnEarlierRecord() throws {
        let holder = try XCTUnwrap(LockHolder.current())
        let holderPath = ResultsFile.holderPath(for: resultsPath)
        try Data("81234 1700000000000000 a-much-longer-host-name.example.com\n".utf8)
            .write(to: URL(fileURLWithPath: holderPath))

        let created = try ResultsFile.Opener().create(in: directory)
        XCTAssertEqual(try String(contentsOfFile: holderPath, encoding: .utf8), holder.line)
        created.close()

        try Data("an earlier record\n".utf8).write(to: URL(fileURLWithPath: holderPath))
        let resumed = try ResultsFile.Opener().openForResume(at: resultsPath)
        defer { resumed.close() }
        XCTAssertEqual(try String(contentsOfFile: holderPath, encoding: .utf8), holder.line)
        XCTAssertEqual(holder.line, "\(getpid()) \(holder.started) \(Provenance.hostName())\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory).sorted(),
            [".results.jsonl.holder", "results.jsonl"],
            "the file the record is written through is gone"
        )
    }

    func test_closing_removesTheHoldersRecord() throws {
        let file = try ResultsFile.Opener().create(in: directory)
        let holderPath = ResultsFile.holderPath(for: file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: holderPath))

        file.close()
        file.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: holderPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["results.jsonl"])
    }

    // An older SwiftMutator, or a holder in the moment before it records itself.
    func test_aHolderThatHasNotRecordedItself_isNotNamed() throws {
        try holdLockWithoutRecording(resultsPath)

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: nil))
        }
    }

    // A run killed at once leaves its record. Naming its process, gone, would send the user looking for it.
    func test_aRecordOfAProcessThatHasEnded_namesNoOne() throws {
        let child = try spawn("/bin/sleep", "30")
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: child))
        kill(child, SIGKILL)
        waitpid(child, nil, 0)
        try writeHoldersRecord("\(child) \(start) \(Provenance.hostName())\n")
        try holdLockWithoutRecording(resultsPath)

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: nil))
        }
    }

    // A killed run's ID can go to another process, which the message would then tell the user to stop.
    func test_aRecordWhoseProcessIDAnotherProcessNowHas_namesNoOne() throws {
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        try writeHoldersRecord("\(getpid()) \(start - 1) \(Provenance.hostName())\n")
        try holdLockWithoutRecording(resultsPath)

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: nil))
        }
    }

    // This host can't ask whether another host's process still runs, so the record is named as only a record.
    func test_aRecordFromAnotherHost_isNamedAsUnchecked() throws {
        try writeHoldersRecord("81234 1700000000000000 another-host.invalid\n")
        try holdLockWithoutRecording(resultsPath)
        let holder = LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "another-host.invalid")

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: .unchecked(holder)))
        }
    }

    func test_aRecordThatIsNotOneWholeLine_namesNoOne() throws {
        try holdLockWithoutRecording(resultsPath)
        for record in ["81234 1700000000000000 another-ho", "\(getpid())\n", "", "not a record\n"] {
            try writeHoldersRecord(record)

            XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath), record) { error in
                XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: nil), record)
            }
        }
    }

    func test_aRecord_namesItsProcess_andItsHostIfItHasOne() {
        XCTAssertEqual(
            LockHolder(record: "81234 1700000000000000 studio.local\n"),
            LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "studio.local")
        )
        XCTAssertEqual(
            LockHolder(record: "81234 1700000000000000\n"),
            LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "")
        )
        XCTAssertEqual(LockHolder(process: 81_234, started: 1, host: "").line, "81234 1\n")
        XCTAssertNil(LockHolder(record: "0 1700000000000000\n"))
    }

    // The record serves only the refusal's message, so a record that can't be written stops nothing.
    func test_aRecordThatCannotBeWritten_stopsNothing() throws {
        let holderPath = ResultsFile.holderPath(for: resultsPath)
        try FileManager.default.createDirectory(atPath: holderPath, withIntermediateDirectories: false)

        let file = try ResultsFile.Opener().create(in: directory)
        XCTAssertTrue(file.append(header))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory).sorted(),
            [".results.jsonl.holder", "results.jsonl"],
            "the file the record is written through is gone"
        )
        file.close()

        XCTAssertEqual(try contents(of: resultsPath), try line(header))
    }

    // `--resume` may reach the file through a linked folder, as /tmp is /private/tmp on macOS.
    func test_aRunReachingTheFileThroughALinkedFolder_namesTheHolder() throws {
        let (folder, link) = try makeDirectoryWithSymbolicLink()
        let running = try ResultsFile.Opener().create(in: folder)
        defer { running.close() }
        let holder = try XCTUnwrap(LockHolder.current())

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: "\(link)/results.jsonl")) { error in
            XCTAssertEqual(
                error as? ResultsFileError,
                .inUse(path: "\(link)/results.jsonl", holder: .running(holder))
            )
        }
    }

    func test_aDescriptorThatCannotBeLocked_isRefused_sayingWhy() {
        XCTAssertThrowsError(try ResultsFile(descriptor: -1, path: "/logs/results.jsonl")) { error in
            XCTAssertEqual(error as? ResultsFileError, .cannotOpen(path: "/logs/results.jsonl", errno: EBADF))
        }
    }

    func test_theLockIsReleasedWhenTheFileCloses() throws {
        let first = try ResultsFile.Opener().create(in: directory)
        first.close()

        let second = try ResultsFile(descriptor: openForAppending(first.path), path: first.path)

        XCTAssertTrue(second.append(header))
    }

    func test_aProcessStartedWhileTheFileIsOpen_doesNotInheritIt_soCannotKeepItLocked() throws {
        let file = try ResultsFile.Opener().create(in: directory)
        // posix_spawn with no attributes passes on every descriptor not marked close-on-exec.
        let child = try spawn("/bin/sleep", "30")
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }

        file.close()

        XCTAssertNoThrow(try ResultsFile(descriptor: openForAppending(file.path), path: file.path))
    }

    // A run killed in the middle of a write leaves its last line cut off, and the next session's first line must not
    // join it: both would be lost to readers.
    func test_openForResume_endsACutOffLastLine_soTheNextLineStandsAlone() throws {
        let earlier = try line(header) + line(mutant).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)

        XCTAssertEqual(try contents(of: resultsPath), earlier, "the line is ended only when the session writes one")
        XCTAssertTrue(file.append(nextHeader))
        XCTAssertEqual(try contents(of: resultsPath), try earlier + Data("\n".utf8) + line(nextHeader))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.unreadableLines, [2])
        XCTAssertFalse(recorded.endsWithCutOffLine)
    }

    func test_openForResume_endsACutOffLastLine_beforeTheFirstLinesWrittenTogether() throws {
        let earlier = try line(header) + line(mutant) + line(MutantResult.make(line: 80)).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let retired = ResultsRetired(session: 2, keys: [mutant.key])

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(contentsOf: [nextHeader, retired]))

        XCTAssertEqual(try contents(of: resultsPath), try earlier + Data("\n".utf8) + line(nextHeader) + line(retired))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.latest, [:], "the retired line is read")
        XCTAssertEqual(recorded.unreadableLines, [3])
    }

    // `--resume` may name a file that isn't a results file, and a resume may be refused, or its baseline fail. Until
    // the session writes a line, the file is left as it was, whatever it holds.
    func test_openForResume_writesNothing_untilALineIsAppended() throws {
        let report = Data(#"{"a":1}"#.utf8)
        try report.write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        file.close()

        XCTAssertEqual(try contents(of: resultsPath), report)
    }

    func test_openForResume_leavesAFileEndingInALineBreakAsItIs() throws {
        let earlier = try line(header) + line(mutant) + line(end)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))

        _ = try ResultsFile.Opener().openForResume(at: resultsPath)

        XCTAssertEqual(try contents(of: resultsPath), earlier)
    }

    // A last line written in full but without its line break reads fine, and must still read once more lines follow.
    func test_openForResume_keepsAWholeLastLineWithoutItsBreakReadable() throws {
        try (line(header) + line(mutant).dropLast()).write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(nextHeader))

        XCTAssertEqual(try contents(of: resultsPath), try line(header) + line(mutant) + line(nextHeader))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.latest, [mutant.key: mutant])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    func test_openForResume_appends_neverOverwrites() throws {
        let earlier = try line(header) + line(mutant) + line(end)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let nextMutant = MutantResult.make(session: 2, line: 80)

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(nextHeader))
        XCTAssertTrue(file.append(nextMutant))

        XCTAssertEqual(file.path, resultsPath)
        XCTAssertEqual(try contents(of: resultsPath), try earlier + line(nextHeader) + line(nextMutant))
        XCTAssertNil(file.writeError)
    }

    // The run that holds the lock may be part way through writing a line: a refused resume must write nothing, not
    // even the line break that would end it.
    func test_openForResume_isRefusedWhileAnotherHoldsTheLock() throws {
        let earlier = try line(header) + line(mutant).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let running = try makeFile()
        let holder = try XCTUnwrap(LockHolder.current())

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: .running(holder)))
        }
        XCTAssertEqual(try contents(of: resultsPath), earlier)

        running.close()
        XCTAssertNoThrow(try ResultsFile.Opener().openForResume(at: resultsPath))
    }

    func test_openForResume_ofAMissingFile_saysWhy() {
        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .cannotOpen(path: resultsPath, errno: ENOENT))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultsPath), "it never makes a file")
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

private extension ResultsFileTests {
    func makeFile(
        writeBytes: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) },
        synchronize: @escaping (Int32) -> Int32 = { fsync($0) }
    ) throws -> ResultsFile {
        let path = "\(directory)/results.jsonl"
        return try ResultsFile(
            descriptor: openForAppending(path),
            path: path,
            writeBytes: writeBytes,
            synchronize: synchronize
        )
    }

    func openForAppending(_ path: String) -> Int32 {
        open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
    }

    /// Locks the file at `path`, made if it's missing, as a holder does before it records itself, until the test ends.
    func holdLockWithoutRecording(_ path: String) throws {
        let descriptor = openForAppending(path)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        addTeardownBlock { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }

    /// Writes `record` where the holder of the file at `resultsPath` records itself.
    func writeHoldersRecord(_ record: String) throws {
        try Data(record.utf8).write(to: URL(fileURLWithPath: ResultsFile.holderPath(for: resultsPath)))
    }

    /// A new folder in `directory`, like a run's log folder, holding empty files with the given names.
    func makeLogFolder(holding names: [String]) throws -> String {
        let folder = "\(directory)/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        for name in names {
            try Data().write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
        }
        return folder
    }

    /// Writes the note the `session`th session of a resumed run leaves in its log folder, `folder`.
    func writeNote(pointingTo path: String, session: Int, in folder: String) throws {
        let note = Data(ResultsFile.note(pointingTo: path, session: session).utf8)
        try note.write(to: URL(fileURLWithPath: "\(folder)/\(ResultsFile.noteFileName)"))
    }

    func contents(of path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func line(_ record: some Encodable) throws -> Data {
        try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
    }
}
