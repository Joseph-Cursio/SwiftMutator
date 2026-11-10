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

/// Where the `swift-mutator` executable starts.
public enum Muter {
    /// Parses the command line and runs the command it names.
    public static func start() async {
        await MuterCommand.main()
    }
}
