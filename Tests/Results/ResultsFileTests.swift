@testable import muterCore
import XCTest

final class ResultsFileTests: XCTestCase {
    private var directory = ""
    private let header = ResultsHeader.make()
    private let mutant = MutantResult.make()
    private let end = ResultsEnd.make()

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

        XCTAssertThrowsError(try ResultsFile(descriptor: second, path: first.path)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: first.path))
        }
        XCTAssertEqual(fcntl(second, F_GETFD), -1, "the refused descriptor is closed")
        XCTAssertTrue(first.append(header))
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

    func test_errorsSayWhatHappened() {
        XCTAssertEqual(
            ResultsFileError.cannotOpen(path: "/logs/results.jsonl", errno: ENOENT).description,
            "can't open /logs/results.jsonl: No such file or directory"
        )
        XCTAssertEqual(
            ResultsFileError.inUse(path: "/logs/results.jsonl").description,
            "/logs/results.jsonl is in use by another SwiftMutator run"
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
            ResultsFileError.newerFormat(path: "/logs/results.jsonl", version: 2).description,
            "/logs/results.jsonl is in results format 2, which only a newer SwiftMutator can read"
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

    func contents(of path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func line(_ record: some Encodable) throws -> Data {
        try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
    }

    /// Starts `arguments[0]` with `arguments`, without closing any descriptor the test has open.
    func spawn(_ arguments: String...) throws -> pid_t {
        var child: pid_t = 0
        let argumentVector = arguments.map { strdup($0) } + [nil]
        defer { argumentVector.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = posix_spawn(&child, arguments[0], nil, nil, argumentVector, &environment)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EPERM) }
        return child
    }
}
