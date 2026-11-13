import ArgumentParser
import Foundation

public struct Init: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Creates the configuration file that SwiftMutator uses"
    )

    // Only the flag is parsed; the folder and the file manager are a test's to set.
    private enum CodingKeys: CodingKey {
        case force
    }

    @Flag(name: .customLong("force"), help: "Replace a muter.conf.yml that is already there.")
    var force = false

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
    }

    public init() {
        // ArgumentParser makes the command with this, then sets `force` from the command line.
    }

    /// Writes a configuration file for the project in `directory`, and says so, which scheme it guessed, and which of
    /// Xcode's trust checks it skips: no run observes it, so it tells the Logger itself. It leaves a file that is
    /// already there alone, unless `force`, as that file may have been edited by hand.
    ///
    /// The generators read the project's files, so they're told the paths are relative to `directory`: otherwise they
    /// would be read from the current folder, which is `directory` only when `init` runs from the command line.
    public mutating func run() async throws {
        @Dependency(\.logger) var logger: Logger
        logger.launched()

        let path = "\(directory)/\(MuterConfiguration.fileNameWithExtension)"
        guard force || !fileManager.fileExists(atPath: path) else {
            throw MuterError.literal(
                reason: "\(path) is already there, so init left it as it is. "
                    + "`swift-mutator init --force` replaces it."
            )
        }

        let directoryContents = fileManager.subpaths(atPath: directory) ?? []
        let generated = try await MuterConfiguration.generated(from: directoryContents, in: directory)
        let text = try ConfigurationFileText.text(for: generated.configuration)
        guard fileManager.createFile(atPath: path, contents: Data(text.utf8), attributes: nil) else {
            throw MuterError.literal(reason: "SwiftMutator could not write \(path).")
        }

        logger.configurationFileCreated(atPath: path)
        logger.schemeGuessed(generated.scheme)
        logger.trustChecksSkipped(XcodebuildTrustCheck.skipped(by: generated.configuration.testCommandArguments))
    }
}
