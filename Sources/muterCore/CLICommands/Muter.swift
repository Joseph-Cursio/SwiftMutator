import ArgumentParser

struct MuterCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "swift-mutator",
        abstract: "🔎 Automated mutation testing for Swift, based on Muter 🕳️",
        version: version,
        subcommands: [
            Init.self,
            Run.self,
            RunWithoutMutating.self,
            MutateWithoutRunning.self,
            Report.self,
            Operator.self,
        ],
        defaultSubcommand: Run.self
    )
}

public enum Muter {
    public static func start() async {
        await MuterCommand.main()
    }
}
