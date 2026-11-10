import ArgumentParser
import Foundation

extension URL: @retroactive ExpressibleByArgument {
    /// A leading `~` is the home folder, as `--report`'s is (`ReportRequest.resolved(in:)`): a shell doesn't expand it
    /// after `--output=` or in quotes, and a report's missing folders are made (`ReportWriter`), so it would otherwise
    /// save into a folder named `~`.
    public init?(argument: String) {
        let path = Self.expandingTilde(argument)
        self = path.contains("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: current.fileManager.currentDirectoryPath + "/" + path)
    }

    /// `path` with a leading `~` or `~user` turned into that home folder; any other path as it is.
    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public var defaultValueDescription: String {
        path == FileManager.default.currentDirectoryPath && isFileURL
            ? "current directory"
            : String(describing: self)
    }
}
