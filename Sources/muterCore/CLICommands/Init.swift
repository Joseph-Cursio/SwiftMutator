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

    public mutating func run() async throws {
        @Dependency(\.events) var events: RunEvents
        events.send(.muterLaunched)

        let directoryContents = fileManager.subpaths(atPath: directory) ?? []
        let configuration = await MuterConfiguration(from: directoryContents)
        fileManager.createFile(
            atPath: "\(directory)/\(MuterConfiguration.fileNameWithExtension)",
            contents: configuration.asData,
            attributes: nil
        )

        events.send(.configurationFileCreated(path: "\(directory)/\(MuterConfiguration.fileNameWithExtension)"))
    }
}
