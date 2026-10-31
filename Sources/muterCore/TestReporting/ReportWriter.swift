import Foundation
import Rainbow

/// Saves reports: the one at the end of a run, the partial one when a run stops early, and those
/// `swift-mutator report` makes.
enum ReportWriter {
    /// Saves `report` at `path`, replacing whatever is there, and says whether it was saved. An empty path, a run's
    /// when no report was requested, saves nothing. The report is saved without colour codes: the plain report is
    /// coloured whenever standard output is a terminal, wherever it goes, and a file is read in an editor, a diff or
    /// a CI log, where they show as noise.
    static func save(_ report: String, to path: String, using fileManager: FileSystemManager) -> Bool {
        guard !path.isEmpty else { return false }
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        return fileManager.createFile(atPath: path, contents: Data(report.raw.utf8), attributes: nil)
    }
}
