import ArgumentParser
import Foundation

struct RunArguments: ParsableArguments {
    @Option(
        name: [.customShort("c"), .customLong("configuration")],
        help: "The path to the configuration file."
    )
    var configurationURL: URL?

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

    @Option(
        name: .customLong("build-timeout"),
        help: ArgumentHelp(
            "Seconds before each step that builds and tests ahead of the first mutant is stopped (the coverage run, "
                + "a build, a baseline), in place of buildTimeout. At most a day, 86400.",
            valueName: "seconds"
        )
    )
    var buildTimeout: Double?

    func validate() throws {
        if let buildTimeout, !(buildTimeout > 0 && buildTimeout <= TestingArguments.longestTimeout) {
            throw ValidationError("--build-timeout must be a number of seconds above 0, and at most a day (86400).")
        }
    }
}
