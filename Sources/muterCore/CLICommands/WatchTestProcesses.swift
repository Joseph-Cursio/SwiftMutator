import ArgumentParser
import Foundation

/// The watcher `TestProcessWatcher` starts, which kills SwiftMutator's test processes if SwiftMutator dies first. Hidden:
/// SwiftMutator starts it itself.
struct WatchTestProcesses: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "watch-test-processes",
        abstract: "Kills the test processes of a SwiftMutator run that dies before them. SwiftMutator starts it itself.",
        shouldDisplay: false
    )

    func run() throws {
        // Run by hand, it would wait for the end of what is typed, and ignore Ctrl-C.
        guard isatty(STDIN_FILENO) == 0 else {
            throw ValidationError("SwiftMutator starts this command itself, reading from a pipe.")
        }
        // Whatever reaches SwiftMutator's process group, or its terminal, when they stop it: the watcher outlives it.
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        TestProcessWatcher.watch(readingFrom: STDIN_FILENO)
    }
}
