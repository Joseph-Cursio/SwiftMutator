import Foundation

/// What a run command does once its flags are read, under `Interruptions` (`RunCommand.run(with:)`).
enum RunWork {
    /// Moves into `--project-folder`, if given, and then runs the steps, so the log folder, the configuration and the
    /// copy all follow from that folder, as they do from the current one without it. It moves before anything else, and
    /// only once: every path on the command line was made absolute, against the folder the command was given in, as
    /// the flags were read, and the steps that move into the copy go back to whatever folder they left. `PWD` is set
    /// to the folder too, so the processes the run starts agree with it.
    @discardableResult
    static func perform(
        with options: Run.Options,
        // A test's steps; nil for the command's own.
        steps: [MutationStep]? = nil,
        settingPWD: (String) -> Void = { setenv("PWD", $0, 1) }
    ) async throws -> RunChecks {
        if let folder = options.projectFolder {
            @Dependency(\.fileManager) var fileManager: FileSystemManager
            guard fileManager.changeCurrentDirectoryPath(folder.path) else {
                throw ProjectFolderRefused(path: folder.path)
            }
            settingPWD(fileManager.currentDirectoryPath)
        }
        let handler = steps.map { MutationTestHandler(options: options, steps: $0) }
            ?? MutationTestHandler(options: options)
        return try await handler.run()
    }
}
