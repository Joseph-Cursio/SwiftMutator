import Foundation

/// Where mutation testing writes its results as it goes, one line at a time.
protocol ResultsRecording: AnyObject {
    var path: String { get }
    /// Why an append failed. After a failure nothing more is written.
    var writeError: Error? { get }
    /// Appends `line` as one line, written out in full and then synchronized with fsync. Once this returns true,
    /// the line survives SwiftMutator being killed, and an OS crash.
    @discardableResult
    func append(_ line: some Encodable) -> Bool
    /// Appends each of `lines`, of any kinds, as a line of its own, as `append` does, but written out in one write and
    /// synchronized once: once this returns true, they all survive. After a failure, any of them may be missing, and
    /// the last one written may be cut off.
    @discardableResult
    func append(contentsOf lines: [any Encodable]) -> Bool
    /// Closes the file, which releases its lock.
    func close()
}

extension ResultsRecording {
    /// One `append` after another, for a file with no faster way.
    @discardableResult
    func append(contentsOf lines: [any Encodable]) -> Bool {
        lines.allSatisfy { append($0) }
    }
}
