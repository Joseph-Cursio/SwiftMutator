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

    /// Writes a configuration file for the project in `directory`, and says so: no run observes it, so it tells the
    /// Logger itself.
    public mutating func run() async throws {
        @Dependency(\.logger) var logger: Logger
        logger.launched()

        let directoryContents = fileManager.subpaths(atPath: directory) ?? []
        let configuration = await MuterConfiguration(from: directoryContents)
        let path = "\(directory)/\(MuterConfiguration.fileNameWithExtension)"
        fileManager.createFile(atPath: path, contents: configuration.asData, attributes: nil)

        logger.configurationFileCreated(atPath: path)
    }
}
