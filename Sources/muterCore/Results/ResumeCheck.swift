import Foundation

/// How the last session a results file recorded differs from the run that would resume it: what refuses the resume,
/// what only `--force-resume` lets through, and what changed that no result depends on. The project's files are
/// compared apart, by `ProjectTree.changes(since:)`.
enum ResumeCheck {
    /// Configuration keys no outcome depends on: a change is only said.
    static let keysThatDontAffectOutcomes: Set = [
        MuterConfiguration.CodingKeys.mutationTestWorkers.stringValue,
        MuterConfiguration.CodingKeys.stopAtFirstFailure.stringValue,
    ]

    /// What the resuming run would record in its header, of what a resume compares.
    struct Current {
        /// As loaded, as a header records it.
        let configuration: MuterConfiguration
        /// By name.
        let operators: [String]
        let filesToMutate: [String]
        let skipCoverage: Bool
        let usingTestPlan: Bool
        let provenance: Provenance
    }

    /// A value the recorded session had and this run has, each as sorted-keys JSON. nil is a configuration key that
    /// isn't set, or a build or toolchain identity that couldn't be read. `name` is the value's key in the header.
    struct Difference: Equatable {
        let name: String
        let was: String?
        let isNow: String?
    }

    struct Verdict: Equatable {
        var refusals: [ResumeRefusal] = []
        /// The names of the build and toolchain differences that `--force-resume` let through.
        var forced: [String] = []
        /// A sentence for each change no result depends on.
        var notices: [String] = []
    }

    /// Compared: every configuration key but `keysThatDontAffectOutcomes`; the operators, `filesToMutate` (both as
    /// sets) and `skipCoverage`; and what identifies the SwiftMutator build, the toolchain and the SDK. Not compared:
    /// SwiftMutator's version and path, which its SHA-256 covers; the process, host and arguments; and the effective
    /// `timeoutSeconds`, `stopsAtFirstFailure` and `failedTestLinesAreReliable`, which follow from the configuration,
    /// the baseline and the timed test run. Only the build and toolchain differences are ever `forced`.
    static func compare(_ recorded: ResultsHeader, with current: Current, forcing: Bool) -> Verdict {
        var verdict = Verdict()
        for difference in configurationDifferences(recorded.configuration, current.configuration) {
            if keysThatDontAffectOutcomes.contains(difference.name) {
                verdict.notices.append(
                    "\(difference.name) \(difference.change(absent: "not set")), which no result depends on."
                )
            } else {
                verdict.refusals.append(.configurationChanged(difference))
            }
        }
        verdict.refusals += selectionDifferences(recorded, current).map(ResumeRefusal.selectionChanged)
        if recorded.usingTestPlan || current.usingTestPlan {
            verdict.refusals.append(.testPlanRun)
        } else if recorded.project == nil {
            verdict.refusals.append(.noProjectTree)
        }
        let builds = provenanceDifferences(
            recorded.provenance,
            current.provenance,
            testCommand: current.configuration.testCommandExecutable
        )
        if forcing {
            verdict.forced = builds.map(\.name)
        } else {
            verdict.refusals += builds.map(ResumeRefusal.needsForce)
        }
        return verdict
    }

    /// Each key's value as sorted-keys JSON, both sides encoded through MuterConfiguration (whose decoder turns an Int
    /// timeout into a Double), over the union of the keys either side has: a new key is compared by default. Sorted
    /// by key.
    static func configurationDifferences(
        _ recorded: MuterConfiguration,
        _ current: MuterConfiguration
    ) -> [Difference] {
        // A side that can't be encoded has no keys, so every key the other has differs.
        let was = values(of: recorded)
        let isNow = values(of: current)
        return Set(was.keys).union(isNow.keys).sorted().compactMap { name in
            was[name] == isNow[name] ? nil : Difference(name: name, was: was[name], isNow: isNow[name])
        }
    }

    /// The differences in which mutants are tested.
    private static func selectionDifferences(_ recorded: ResultsHeader, _ current: Current) -> [Difference] {
        [
            difference("operators", Set(recorded.operators).sorted(), Set(current.operators).sorted()),
            difference("filesToMutate", Set(recorded.filesToMutate).sorted(), Set(current.filesToMutate).sorted()),
            difference("skipCoverage", recorded.skipCoverage, current.skipCoverage),
        ].compactMap { $0 }
    }

    /// The differences in what identifies the SwiftMutator build, the toolchain and the SDK, named by their keys in
    /// the header's `provenance`. An identity that couldn't be read is a difference even if it is unknown on both
    /// sides, as nothing shows the two to be the same: SwiftMutator's SHA-256, and the test command's version, or,
    /// for a test command other than `swift` or `xcodebuild`, its SHA-256.
    private static func provenanceDifferences(
        _ recorded: Provenance,
        _ current: Provenance,
        testCommand: String
    ) -> [Difference] {
        let askedItsVersion = Provenance.Toolchain.isAskedItsVersion(testCommand)
        let identities: [(name: String, was: String?, isNow: String?, identifies: Bool)] = [
            (
                "swiftMutator.executableSHA256",
                recorded.swiftMutator.executableSHA256,
                current.swiftMutator.executableSHA256,
                true
            ),
            (
                "toolchain.testCommandVersion",
                recorded.toolchain.testCommandVersion,
                current.toolchain.testCommandVersion,
                askedItsVersion
            ),
            (
                "toolchain.testExecutableSHA256",
                recorded.toolchain.testExecutableSHA256,
                current.toolchain.testExecutableSHA256,
                !askedItsVersion
            ),
        ]
        var differences = identities.compactMap { identity -> Difference? in
            let unknown = identity.identifies && (identity.was == nil || identity.isNow == nil)
            guard unknown || identity.was != identity.isNow else { return nil }
            return Difference(
                name: identity.name,
                was: identity.was.flatMap { json($0) },
                isNow: identity.isNow.flatMap { json($0) }
            )
        }
        if let environment = difference(
            "toolchain.environment",
            recorded.toolchain.environment,
            current.toolchain.environment
        ) {
            differences.append(environment)
        }
        return differences
    }

    private static func difference<Value: Encodable & Equatable>(
        _ name: String,
        _ was: Value,
        _ isNow: Value
    ) -> Difference? {
        was == isNow ? nil : Difference(name: name, was: json(was), isNow: json(isNow))
    }

    /// `configuration`'s keys and their values, each as sorted-keys JSON.
    private static func values(of configuration: MuterConfiguration) -> [String: String] {
        guard let data = try? JSONEncoder().encode(configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object.compactMapValues { value in
            (try? JSONSerialization.data(withJSONObject: value, options: jsonOptions))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private static func json<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static let jsonOptions: JSONSerialization.WritingOptions = [
        .sortedKeys,
        .fragmentsAllowed,
        .withoutEscapingSlashes,
    ]

    /// What a build or toolchain identity is of, in words, by its name.
    static func subject(of name: String) -> String {
        [
            "swiftMutator.executableSHA256": "SwiftMutator",
            "toolchain.testCommandVersion": "The toolchain",
            "toolchain.testExecutableSHA256": "The test command",
            "toolchain.environment": "The toolchain's environment",
        ][name] ?? name
    }
}

extension ResumeCheck.Current {
    /// What `state` would record in its header: the configuration as loaded, and the mutants asked for.
    init(state: AnyMutationTestState, provenance: Provenance) {
        self.init(
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            provenance: provenance
        )
    }
}

extension ResumeCheck.Difference {
    /// "was 60 and is 120 now", with `absent` for a value that is nil.
    func change(absent: String) -> String {
        "was \(was ?? absent) and is \(isNow ?? absent) now"
    }
}
