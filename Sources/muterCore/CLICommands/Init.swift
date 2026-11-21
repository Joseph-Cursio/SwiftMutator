import ArgumentParser
import Foundation

public struct Init: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Creates the configuration file that SwiftMutator uses"
    )

    // Only the flags are parsed; the current folder and the file manager are a test's to set.
    private enum CodingKeys: CodingKey {
        case force
        case projectFolder
    }

    @Flag(name: .customLong("force"), help: "Replace a muter.conf.yml that is already there.")
    var force = false

    @Option(
        name: .customLong("project-folder"),
        help: ArgumentHelp(
            "Write it in this folder, for the project there, in place of the current folder.",
            valueName: "path"
        )
    )
    var projectFolder: URL?

    private var directory = FileManager.default.currentDirectoryPath
    private var fileManager = FileManager.default

    public init(
        directory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = FileManager.default,
        force: Bool = false
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.force = force
        projectFolder = nil
    }

    public init() {
        // ArgumentParser makes the command with this, then sets `force` and `projectFolder` from the command line.
    }

    /// The folder of the project the file is written for: `--project-folder`, else the current folder.
    private var projectDirectory: String {
        projectFolder?.path ?? directory
    }

    public func validate() throws {
        if let projectFolder, !fileManager.isDirectory(atPath: projectFolder.path) {
            throw ValidationError("--project-folder must be a folder, and \(projectFolder.path) isn't one.")
        }
    }

    /// Writes a configuration file for the project in `projectDirectory`, and says so, which scheme it guessed, and
    /// which of Xcode's trust checks it skips: no run observes it, so it tells the Logger itself. It leaves a file that
    /// is already there alone, unless `force`, as that file may have been edited by hand.
    ///
    /// The generators read the project's files, so they're told the paths are relative to `projectDirectory`: otherwise
    /// they would be read from the current folder, which is that folder only when `init` runs from the command line
    /// without `--project-folder`.
    public mutating func run() async throws {
        @Dependency(\.logger) var logger: Logger
        logger.launched()

        let folder = projectDirectory
        let path = "\(folder)/\(MuterConfiguration.fileNameWithExtension)"
        guard force || !fileManager.fileExists(atPath: path) else {
            throw MuterError.literal(
                reason: "\(path) is already there, so init left it as it is. "
                    + "`swift-mutator init --force` replaces it."
            )
        }

        let directoryContents = fileManager.subpaths(atPath: folder) ?? []
        let generated = try await MuterConfiguration.generated(from: directoryContents, in: folder)
        let text = try ConfigurationFileText.text(for: generated.configuration)
        guard fileManager.createFile(atPath: path, contents: Data(text.utf8), attributes: nil) else {
            throw MuterError.literal(reason: "SwiftMutator could not write \(path).")
        }

        logger.configurationFileCreated(atPath: path)
        logger.schemeGuessed(generated.scheme)
        logger.trustChecksSkipped(XcodebuildTrustCheck.skipped(by: generated.configuration.testCommandArguments))
    }
}
