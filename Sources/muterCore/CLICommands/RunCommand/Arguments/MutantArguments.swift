import ArgumentParser
import Foundation

/// The one mutant a run tests on its own, for `run` and `run-without-mutating`.
struct MutantArguments: ParsableArguments {
    @Option(
        name: .customLong("mutant"),
        help: ArgumentHelp(
            "Test only this mutant, and print its change, its tests' log and its verdict: path:line[:column] "
                + "[Operator], as the progress lines and reports name it, such as 'Bar.swift:12:9' or "
                + "'Sources/Foo/Bar.swift:12:9 SwapTernary'.",
            valueName: "mutant"
        ),
        transform: { try MutantReference.parse($0) }
    )
    var mutant: MutantReference?
}
