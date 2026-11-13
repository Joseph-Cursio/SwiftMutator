import Foundation
import Rainbow

/// Saves reports: the one at the end of a run, the partial one when a run stops early, and those
/// `swift-mutator report` makes.
enum ReportWriter {
    /// Saves `report` at `path`, replacing whatever is there, and says whether it was saved. An empty path, a run's
    /// when no report was requested, saves nothing. The report is saved without colour codes: the plain report is
    /// coloured whenever standard output is a terminal, wherever it goes, and a file is read in an editor, a diff or
    /// a CI log, where they show as noise.
    ///
    /// A folder on the way to `path` that isn't there is made first, as a CI job that names `out/mutants.sarif` has
    /// usually made no `out` folder: without it the report couldn't be saved, and a run, which only warns of that,
    /// would pass with none. One that can't be made, such as one where a file is, leaves the report unsaved.
    static func save(_ report: String, to path: String, using fileManager: FileSystemManager) -> Bool {
        guard !path.isEmpty else { return false }
        let folder = path.deletingLastPathComponent
        if !folder.isEmpty {
            // Nothing to make for a folder that is there, which `withIntermediateDirectories` doesn't refuse.
            try? fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: nil)
        }
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        return fileManager.createFile(atPath: path, contents: Data(report.raw.utf8), attributes: nil)
    }
}
