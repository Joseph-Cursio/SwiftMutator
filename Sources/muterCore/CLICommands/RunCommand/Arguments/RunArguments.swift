import ArgumentParser
import Foundation

/// What every command that loads a configuration takes: where the project and its configuration are, what it prints,
/// and how the project is built.
struct RunArguments: ParsableArguments, KeyFlagArguments {
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

    @Option(
        name: .customLong("build-system"),
        help: ArgumentHelp(
            "The build system, swift or xcodebuild, for an executable whose file name isn't one, such as a wrapper "
                + "script, in place of buildSystem.",
            valueName: "swift|xcodebuild"
        ),
        transform: { text in
            guard let system = BuildSystem(written: text) else {
                throw ValidationError("give swift or xcodebuild.")
            }
            return system
        }
    )
    var buildSystem: BuildSystem?

    @Option(
        name: .customLong("workspace"),
        help: ArgumentHelp(
            "The Xcode workspace to test, relative to the project's folder, in place of the workspace and project "
                + "keys and any -workspace or -project in arguments.",
            valueName: "path"
        )
    )
    var workspace: String?

    @Option(
        name: .customLong("project"),
        help: ArgumentHelp(
            "The Xcode project to test, relative to the project's folder, in place of the workspace and project keys "
                + "and any -workspace or -project in arguments.",
            valueName: "path"
        )
    )
    var project: String?

    @Option(
        name: .customLong("scheme"),
        help: ArgumentHelp(
            "The scheme to build and test, in place of the scheme key and any -scheme in arguments.",
            valueName: "name"
        )
    )
    var scheme: String?

    @Option(
        name: .customLong("destination"),
        help: ArgumentHelp(
            "Where to test, as xcodebuild's -destination takes it, in place of the destination key and every "
                + "-destination in arguments; mutants are tested on the first. Repeatable.",
            valueName: "specifier"
        )
    )
    var destinations: [String] = []

    @Option(
        name: .customLong("keep-log-folders"),
        help: ArgumentHelp(
            "How many runs' log folders to keep, this run's included, at least 2, in place of keepLogFolders.",
            valueName: "count"
        )
    )
    var keepLogFolders: Int?

    /// What `--workspace`, `--project`, `--scheme` and `--destination` give.
    var xcodebuild: XcodebuildChoice {
        XcodebuildChoice(workspace: workspace, project: project, scheme: scheme, destinations: destinations)
    }

    /// The project folder is only checked here: the run moves into it once it starts (`RunCommand.run(with:)`), as
    /// the flags are also read by tests, which never move.
    func validate() throws {
        if let projectFolder, !current.fileManager.isDirectory(atPath: projectFolder.path) {
            throw ValidationError("--project-folder must be a folder, and \(projectFolder.path) isn't one.")
        }
        if quiet, verbose {
            throw ValidationError("--quiet and --verbose can't be given together.")
        }
        try validateXcodebuildChoice()
        if let buildTimeout, !(buildTimeout > 0 && buildTimeout <= TestingArguments.longestTimeout) {
            throw ValidationError("--build-timeout must be a number of seconds above 0, and at most a day (86400).")
        }
        try Self.refuse(keepLogFolders, of: "--keep-log-folders", outside: MuterConfiguration.logFolderCounts)
    }

    func set(in flags: inout KeyFlags) {
        flags.buildSystem = buildSystem
        flags.keepLogFolders = keepLogFolders
    }

    /// xcodebuild opens one workspace or project, and a blank value would give it none.
    private func validateXcodebuildChoice() throws {
        if workspace != nil, project != nil {
            throw ValidationError("--workspace and --project can't be given together: xcodebuild opens one of them.")
        }
        let given: [(flag: String, value: String?)] = [
            ("--workspace", workspace), ("--project", project), ("--scheme", scheme),
        ] + destinations.map { ("--destination", $0) }
        if let blank = given.first(where: { $0.value?.trimmed.isEmpty == true }) {
            throw ValidationError("\(blank.flag) can't be blank.")
        }
    }
}
