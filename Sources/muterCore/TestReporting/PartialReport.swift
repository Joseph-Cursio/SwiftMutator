import Foundation

/// The report of what mutation testing tested before it stopped early.
enum PartialReport {
    /// Beside the requested report, and never replacing it: `report.txt` gives `report.partial.txt`, and `report`
    /// gives `report.partial`. Without a requested report there is no partial one: the summary printed when mutation
    /// testing stops, and the results file, say what was tested.
    static func path(besides requested: String?) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let path = requested as NSString
        let stem = path.deletingPathExtension
        return path.pathExtension.isEmpty ? stem + ".partial" : stem + ".partial." + path.pathExtension
    }
}
