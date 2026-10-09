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
        help: "Lists how many mutants are in each file that has any, and the Swift files found, if the command looks for them."
    )
    var verbose: Bool = false
}
