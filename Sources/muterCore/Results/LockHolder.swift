import Foundation

/// The process that holds a results file's lock, as it records itself while it holds it: its ID, when it started,
/// which tells it apart from a later process given the same ID, and the host it runs on.
struct LockHolder: Equatable, Sendable, CustomStringConvertible {
    let process: Int32
    let started: UInt64
    /// Empty when gethostname fails, so the record names no host.
    let host: String

    /// This process, or nil if its start can't be read.
    static func current() -> Self? {
        let ownProcess = getpid()
        return MutatedProjectLock.startTime(of: ownProcess).map {
            Self(process: ownProcess, started: $0, host: Provenance.hostName())
        }
    }

    init(process: Int32, started: UInt64, host: String) {
        self.process = process
        self.started = started
        self.host = host
    }

    /// The holder a record names, or nil if the record isn't one whole line ending in a line break. A record read
    /// while it was being written is never one.
    init?(record: Substring) {
        guard let end = record.firstIndex(of: "\n") else { return nil }
        // The host is the rest of the line, so a record that names none has two fields.
        let fields = record[..<end].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3, let recordedProcess = Int32(fields[0]), recordedProcess > 0,
              let startTime = UInt64(fields[1])
        else { return nil }
        self.init(process: recordedProcess, started: startTime, host: fields.count == 3 ? String(fields[2]) : "")
    }

    /// The record's line: `<pid> <start> <host>`, or `<pid> <start>` when the host is empty, ending in a line break.
    var line: String {
        host.isEmpty ? "\(process) \(started)\n" : "\(process) \(started) \(host)\n"
    }

    /// Whether this host can check the record: it names no host, or this host.
    var isOnThisHost: Bool {
        host.isEmpty || host == Provenance.hostName()
    }

    /// Whether the record's process still runs with the recorded start. Only for a record on this host: another
    /// host's processes can't be asked about.
    var stillRuns: Bool {
        MutatedProjectLock.startTime(of: process) == started
    }

    /// The process, and its host if the record names one: "process 81234 on studio.local".
    var description: String {
        host.isEmpty ? "process \(process)" : "process \(process) on \(host)"
    }
}
