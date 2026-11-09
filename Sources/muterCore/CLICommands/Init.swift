import ArgumentParser
import Foundation

public struct Init: AsyncParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Creates the configuration file that SwiftMutator uses"
    )

    private let directory: String
    private let fileManager: FileManager

    public init(
        directory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = FileManager.default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public init(from decoder: Decoder) throws {
        self.init(
            directory: FileManager.default.currentDirectoryPath,
            fileManager: .default
        )
    }

    public init() {
        self.init(
            directory: FileManager.default.currentDirectoryPath,
            fileManager: .default
        )
    }

    /// Writes a configuration file for the project in `directory`, and says so, and which of Xcode's trust checks it
    /// skips: no run observes it, so it tells the Logger itself.
    ///
    /// The generators read the project's files, so they're told the paths are relative to `directory`: otherwise they
    /// would be read from the current folder, which is `directory` only when `init` runs from the command line.
    public mutating func run() async throws {
        @Dependency(\.logger) var logger: Logger
        logger.launched()

        let directoryContents = fileManager.subpaths(atPath: directory) ?? []
        let configuration = await MuterConfiguration(from: directoryContents, in: directory)
        let path = "\(directory)/\(MuterConfiguration.fileNameWithExtension)"
        guard fileManager.createFile(atPath: path, contents: try configuration.asData, attributes: nil) else {
            throw MuterError.literal(reason: "SwiftMutator could not write \(path).")
        }

        logger.configurationFileCreated(atPath: path)
        logger.trustChecksSkipped(XcodebuildTrustCheck.skipped(by: configuration.testCommandArguments))
    }
}
