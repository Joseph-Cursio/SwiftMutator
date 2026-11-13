@testable import muterCore
import XCTest

extension ResultsFileTests {
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
}
