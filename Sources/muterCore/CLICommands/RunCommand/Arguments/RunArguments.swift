import ArgumentParser
import Foundation

struct RunArguments: ParsableArguments {
    @Option(
        name: [.customShort("c"), .customLong("configuration")],
        help: "The path to the configuration file."
    )
    var configurationURL: URL?

    @Option(
        name: .customLong("project-folder"),
        help: ArgumentHelp(
            "The project's folder, in place of the current folder. Paths given in other flags, such as -c and -o, are "
                + "still the current folder's; those that pick files in the project, such as --files-to-mutate, are "
                + "the project's.",
            valueName: "path"
        )
    )
    var projectFolder: URL?

    @Flag(
        name: [.customLong("skip-coverage")],
        help: "Skips the step in which SwiftMutator runs your project in order to filter out files without coverage."
    )
    var skipCoverage: Bool = false

    @Flag(
        name: [.customLong("skip-update-check")],
        help: "Skips the step in which SwiftMutator checks for newer versions."
    )
    var skipUpdateCheck: Bool = false

    @Flag(
        name: [.customLong("verbose")],
        help: ArgumentHelp(
            "Lists how many mutants are in each file that has any, and the Swift files found, if the command "
                + "looks for them."
        )
    )
    var verbose: Bool = false

    @Flag(
        name: [.customLong("quiet")],
        help: "Prints only warnings, errors and the run's summary: no banner, progress or notices."
    )
    var quiet: Bool = false

    @Option(
        name: .customLong("build-timeout"),
        help: ArgumentHelp(
            "Seconds before each step that builds and tests ahead of the first mutant is stopped (the coverage run, "
                + "a build, a baseline), in place of buildTimeout. At most a day, 86400.",
            valueName: "seconds"
        )
    )
    var buildTimeout: Double?

    /// The project folder is only checked here: the run moves into it once it starts (`RunCommand.run(with:)`), as
    /// the flags are also read by tests, which never move.
    func validate() throws {
        if let projectFolder, !current.fileManager.isDirectory(atPath: projectFolder.path) {
            throw ValidationError("--project-folder must be a folder, and \(projectFolder.path) isn't one.")
        }
        if quiet, verbose {
            throw ValidationError("--quiet and --verbose can't be given together.")
        }
        if let buildTimeout, !(buildTimeout > 0 && buildTimeout <= TestingArguments.longestTimeout) {
            throw ValidationError("--build-timeout must be a number of seconds above 0, and at most a day (86400).")
        }
    }
}
