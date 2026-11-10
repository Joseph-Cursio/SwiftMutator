@testable import muterCore
import XCTest

extension ResultsFileTests {
    /// One folder for the process: its tests run one at a time, and each makes the folder in `setUp` and removes it
    /// after.
    private static let processDirectory = XCTestCase.unusedTemporaryPath()

    /// The folder the test works in, made in `setUp` and removed after it.
    var directory: String { Self.processDirectory }

    /// The header a new session writes.
    var header: ResultsHeader { ResultsHeader.make() }

    /// A mutant's record.
    var mutant: MutantResult { MutantResult.make() }

    /// The record a session ends with.
    var end: ResultsEnd { ResultsEnd.make() }

    /// The header a resumed session appends.
    var nextHeader: ResultsHeader { ResultsHeader.make(formatVersion: ResultsCoding.resumedFormatVersion, session: 2) }

    /// Where the folder's first results file is.
    var resultsPath: String {
        "\(directory)/results.jsonl"
    }

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
