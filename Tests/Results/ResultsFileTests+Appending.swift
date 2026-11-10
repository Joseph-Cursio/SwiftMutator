@testable import muterCore
import XCTest

extension ResultsFileTests {
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
        let file = try makeFile { descriptor, bytes, count in
            writes += 1
            switch writes {
            case 1: return write(descriptor, bytes, count)
            case 2: return write(descriptor, bytes, 10)

            default:
                errno = ENOSPC
                return -1
            }
        }

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
}
