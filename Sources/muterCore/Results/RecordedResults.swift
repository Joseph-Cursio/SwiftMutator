import Foundation

/// What a results file recorded, read leniently: a line that doesn't read (the last line of a run killed while
/// writing it, NUL padding after a power loss, a garbled line) is skipped and its number kept, never fatal. Only a
/// file with no header, or one a newer SwiftMutator wrote, is refused. Reading takes no lock, so it reads a file a
/// run is still writing.
struct RecordedResults {
    /// One session of mutation testing in the file: its header, its end line if it wrote one, and when its last
    /// mutant finished.
    struct Session: Equatable {
        let header: ResultsHeader
        var end: ResultsEnd?
        var lastFinishedAt: Date?

        /// The end line's test duration; without one, from the session's start to its last mutant's finish.
        var testDuration: TimeInterval {
            if let end {
                return end.testDurationSeconds
            }
            guard let lastFinishedAt else { return 0 }
            return max(lastFinishedAt.timeIntervalSince(header.startedAt), 0)
        }
    }

    private(set) var sessions: [Session] = []
    /// Each key's last record.
    private(set) var latest: [MutantKey: MutantResult] = [:]
    /// The 1-based numbers of the lines skipped: those that don't read as a record, and records of a session no
    /// earlier header started. Empty lines, and kinds of record this SwiftMutator doesn't know, aren't among them.
    private(set) var unreadableLines: [Int] = []
    /// Whether the file ends in a line without its line break that doesn't read, which is then the last of
    /// `unreadableLines`: SwiftMutator was stopped while writing it.
    private(set) var endsWithCutOffLine = false

    var headers: [ResultsHeader] {
        sessions.map(\.header)
    }

    /// How long mutation testing took, over every session.
    var testDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.testDuration }
    }

    /// The results `data`, the contents of the file at `path`, recorded.
    static func read(_ data: Data, path: String) throws -> RecordedResults {
        var results = RecordedResults()
        let decoder = ResultsCoding.decoder
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            if try !results.add(Data(line), path: path, using: decoder) {
                results.unreadableLines.append(index + 1)
            }
        }
        // The last line is empty when the file ends in a line break, and an empty line is never unreadable.
        results.endsWithCutOffLine = results.unreadableLines.last == lines.count
        guard !results.sessions.isEmpty else { throw ResultsFileError.notAResultsFile(path: path) }
        return results
    }

    /// Adds `line`'s record, or returns false if it doesn't read. A header a newer SwiftMutator wrote refuses the
    /// file, as the lines after it may mean something else.
    private mutating func add(_ line: Data, path: String, using decoder: JSONDecoder) throws -> Bool {
        guard let kind = try? decoder.decode(ResultsCoding.Kind.self, from: line).kind else { return false }
        switch kind {
        case "header":
            if let version = try? decoder.decode(FormatVersion.self, from: line).formatVersion,
               version > ResultsCoding.formatVersion {
                throw ResultsFileError.newerFormat(path: path, version: version)
            }
            guard let header = try? decoder.decode(ResultsHeader.self, from: line) else { return false }
            sessions.append(Session(header: header))
        case "mutant":
            guard let record = try? decoder.decode(MutantResult.self, from: line),
                  let session = sessionIndex(record.session)
            else { return false }
            latest[record.key] = record
            sessions[session].lastFinishedAt = max(sessions[session].lastFinishedAt ?? .distantPast, record.finishedAt)
        case "end":
            guard let end = try? decoder.decode(ResultsEnd.self, from: line),
                  let session = sessionIndex(end.session)
            else { return false }
            sessions[session].end = end
        default:
            // A kind of record a later SwiftMutator writes.
            break
        }
        return true
    }

    /// The latest session an earlier header started with `number`.
    private func sessionIndex(_ number: Int) -> Int? {
        sessions.lastIndex { $0.header.session == number }
    }

    private struct FormatVersion: Decodable {
        let formatVersion: Int
    }
}
