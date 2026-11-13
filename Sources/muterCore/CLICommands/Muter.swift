import ArgumentParser

struct MuterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-mutator",
        abstract: "🔎 Automated mutation testing for Swift, based on Muter 🕳️",
        version: version,
        subcommands: [
            Init.self,
            Run.self,
            RunWithoutMutating.self,
            MutateWithoutRunning.self,
            Report.self,
            Triage.self,
            Operator.self,
            WatchTestProcesses.self,
        ],
        defaultSubcommand: Run.self
    )
}

/// The entry point of the `swift-mutator` executable.
public enum Muter {
    /// Parses the command line and runs the command it names, or `run` when it names none.
    public static func start() async {
        await MuterCommand.main()
    }
}
