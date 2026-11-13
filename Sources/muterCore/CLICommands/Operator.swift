import ArgumentParser
import Rainbow

public struct Operator: ParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "operator",
        abstract: "Describes a given mutation operator."
    )

    @Argument(
        help: """
            Available operators are: \(MutationOperator.Id.description)
            For all operators use: \("all".italic)
        """
    )
    var `operator`: String

    public init() {
        // ArgumentParser sets the properties from the command line.
    }

    public mutating func run() throws {
        @Dependency(\.printer) var print: Printer
        if `operator`.trimmed == "all" {
            print(MutationOperator.Id.allCases.map(\.documentation).joined(separator: "\n\n"))
            return
        }

        guard let mutationOperator = MutationOperator.Id(rawValue: `operator`) else {
            throw MuterError.literal(reason: MutationOperator.Id.description)
        }

        print(mutationOperator.documentation)
    }
}
