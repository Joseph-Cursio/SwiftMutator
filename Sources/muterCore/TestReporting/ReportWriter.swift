import Foundation

/// Saves reports: the one at the end of a run, and the partial one when a run stops early.
enum ReportWriter {
    /// Saves `report` at `path`, replacing whatever is there, and says whether it was saved. An empty path, a run's
    /// when no report was requested, saves nothing.
    static func save(_ report: String, to path: String, using fileManager: FileSystemManager) -> Bool {
        guard !path.isEmpty else { return false }
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        return fileManager.createFile(atPath: path, contents: Data(report.utf8), attributes: nil)
    }
}
