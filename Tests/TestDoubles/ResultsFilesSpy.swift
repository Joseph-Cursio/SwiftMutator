import Foundation
@testable import muterCore

/// A record a results file holds, known by its `kind`.
protocol ResultsRecord: Decodable {
    static var recordKind: String { get }
}

extension ResultsHeader: ResultsRecord {
    static let recordKind = "header"
}

extension MutantResult: ResultsRecord {
    static let recordKind = "mutant"
}

extension ResultsEnd: ResultsRecord {
    static let recordKind = "end"
}

/// Makes results files in memory. Each keeps its lines as a results file would write them.
final class ResultsFilesSpy: ResultsFileOpening {
    final class File: ResultsRecording {
        let path: String
        private(set) var writeError: Error?
        /// Each line appended, without its line break.
        private(set) var lines: [String] = []
        private(set) var isClosed = false
        /// The 1-based number of the first line whose append fails, as on a full disk.
        private let failFromLine: Int?
        private let encoder = ResultsCoding.encoder

        init(path: String, failFromLine: Int?) {
            self.path = path
            self.failFromLine = failFromLine
        }

        @discardableResult
        func append(_ line: some Encodable) -> Bool {
            guard writeError == nil, !isClosed else { return false }
            do {
                if let failFromLine, lines.count + 1 >= failFromLine {
                    throw ResultsFileError.cannotWrite(path: path, errno: ENOSPC)
                }
                lines.append(String(decoding: try encoder.encode(line), as: UTF8.self))
                return true
            } catch {
                writeError = error
                return false
            }
        }

        func close() {
            isClosed = true
        }
    }

    /// Thrown by `create` instead of making a file.
    var errorToThrow: Error?
    /// Thrown by `openForResume` instead of opening the file.
    var resumeErrorToThrow: Error?
    /// The 1-based number of the first line whose append fails in each file made or opened.
    var failFromLine: Int?
    /// The folders a file was asked for in, in order.
    private(set) var directories: [String] = []
    /// The paths a file was asked to be opened at for resuming, in order.
    private(set) var resumedPaths: [String] = []
    /// Each file made or opened, in order. A file opened for resuming holds only the lines appended since.
    private(set) var files: [File] = []

    func create(in directory: String) throws -> ResultsRecording {
        directories.append(directory)
        if let errorToThrow {
            throw errorToThrow
        }
        let file = File(path: "\(directory)/results.jsonl", failFromLine: failFromLine)
        files.append(file)
        return file
    }

    func openForResume(at path: String) throws -> ResultsRecording {
        resumedPaths.append(path)
        if let resumeErrorToThrow {
            throw resumeErrorToThrow
        }
        let file = File(path: path, failFromLine: failFromLine)
        files.append(file)
        return file
    }

    /// Every line of every file made or opened, in order.
    var lines: [String] {
        files.flatMap(\.lines)
    }

    /// The records of `Record`'s kind among `lines`, in order.
    func records<Record: ResultsRecord>(_ type: Record.Type) throws -> [Record] {
        let decoder = ResultsCoding.decoder
        return try lines.map { Data($0.utf8) }
            .filter { try decoder.decode(ResultsCoding.Kind.self, from: $0).kind == Record.recordKind }
            .map { try decoder.decode(Record.self, from: $0) }
    }

    /// Each line's kind, in order.
    func kinds() throws -> [String] {
        let decoder = ResultsCoding.decoder
        return try lines.map { try decoder.decode(ResultsCoding.Kind.self, from: Data($0.utf8)).kind }
    }
}
