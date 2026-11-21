import ArgumentParser

/// How the commands that make the mutated copy of the project treat it: `run` and `mutate-without-running`.
struct ProjectCopyArguments: ParsableArguments, KeyFlagArguments {
    // nil when neither flag is given, which leaves the key.
    // swiftlint:disable discouraged_optional_boolean
    @Flag(
        name: .customLong("keep-swiftlint-phases"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Keep SwiftLint running in the build phases of the copy's Xcode projects, or turn it off there, in "
                + "place of keepSwiftLintPhases."
        )
    )
    var keepSwiftLintPhases: Bool?
    // swiftlint:enable discouraged_optional_boolean

    func set(in flags: inout KeyFlags) {
        flags.keepSwiftLintPhases = .given(keepSwiftLintPhases)
    }
}
