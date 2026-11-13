import Foundation

extension ResumeCheck {
    /// One identity of the build or the toolchain, as the recorded session and this run have it, and whether it
    /// identifies them here, so that being unknown is a difference (`provenanceDifferences`).
    private struct ProvenanceIdentity {
        let name: String
        let was: String?
        let isNow: String?
        let identifies: Bool
    }

    /// The differences in which mutants are tested. A run of one mutant (`--mutant`) differs from any other, so no
    /// whole run continues it, whatever the purpose.
    static func selectionDifferences(_ recorded: ResultsHeader, _ current: Current) -> [Difference] {
        [
            difference("operators", Set(recorded.operators).sorted(), Set(current.operators).sorted()),
            difference("filesToMutate", Set(recorded.filesToMutate).sorted(), Set(current.filesToMutate).sorted()),
            difference("skipCoverage", recorded.skipCoverage, current.skipCoverage),
            recorded.mutant == current.mutant ? nil : Difference(
                name: "mutant",
                was: recorded.mutant.flatMap { json($0) },
                isNow: current.mutant.flatMap { json($0) }
            ),
        ].compactMap(\.self)
    }

    /// The differences in what `--since` compares the working tree with, by their keys in the header's `since`: its
    /// merge base, and `--changed-lines`. Not the ref as given, as one that moved since names another merge base; nor
    /// the files and lines it chose, which follow from the working tree: a changed file is compared as the project's
    /// files are, and its mutants tested again, and a mutant no longer chosen is a mutant no longer discovered.
    static func sinceDifferences(_ recorded: ChangeSelection?, _ current: ChangeSelection?) -> [Difference] {
        switch (recorded, current) {
        case (nil, nil):
            return []

        case let (recorded?, current?):
            return [
                difference("since.mergeBase", recorded.mergeBase, current.mergeBase),
                difference("since.changedLines", recorded.changedLines, current.changedLines),
            ].compactMap(\.self)

        default:
            return [
                Difference(
                    name: "since",
                    was: recorded.flatMap { json($0.ref) },
                    isNow: current.flatMap { json($0.ref) }
                ),
            ]
        }
    }

    /// The difference in which shard is tested, by its `k/n`, which says all there is: which of the mutants discovered
    /// are in a shard follows from their places alone.
    static func shardDifference(_ recorded: ShardSelection?, _ current: Shard?) -> Difference? {
        guard recorded?.shard != current else { return nil }
        return Difference(
            name: "shard",
            was: recorded.flatMap { json($0.shard.description) },
            isNow: current.flatMap { json($0.description) }
        )
    }

    /// The difference in which sample is tested, by its size and seed, which say all there is: which of the mutants
    /// discovered are in a sample follows from their places alone. Its value is "N, seed S".
    static func sampleDifference(_ recorded: SampleSelection?, _ current: Sample?) -> Difference? {
        let was = recorded.map { "\($0.size), seed \($0.seed)" }
        let isNow = current.map { "\($0.size), seed \($0.seed)" }
        guard was != isNow else { return nil }
        return Difference(name: "sample", was: was.flatMap { json($0) }, isNow: isNow.flatMap { json($0) })
    }

    /// The differences in what identifies the SwiftMutator build, the toolchain and the SDK, named by their keys in
    /// the header's `provenance`. An identity that couldn't be read is a difference even if it is unknown on both
    /// sides, as nothing shows the two to be the same: SwiftMutator's SHA-256, and the test command's version, or,
    /// for a test command other than `swift` or `xcodebuild`, its SHA-256.
    static func provenanceDifferences(
        _ recorded: Provenance,
        _ current: Provenance,
        testCommand: String
    ) -> [Difference] {
        let askedItsVersion = Provenance.Toolchain.isAskedItsVersion(testCommand)
        let identities = [
            ProvenanceIdentity(
                name: "swiftMutator.executableSHA256",
                was: recorded.swiftMutator.executableSHA256,
                isNow: current.swiftMutator.executableSHA256,
                identifies: true
            ),
            ProvenanceIdentity(
                name: "toolchain.testCommandVersion",
                was: recorded.toolchain.testCommandVersion,
                isNow: current.toolchain.testCommandVersion,
                identifies: askedItsVersion
            ),
            ProvenanceIdentity(
                name: "toolchain.testExecutableSHA256",
                was: recorded.toolchain.testExecutableSHA256,
                isNow: current.toolchain.testExecutableSHA256,
                identifies: !askedItsVersion
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

    static func difference<Value: Encodable & Equatable>(
        _ name: String,
        _ was: Value,
        _ isNow: Value
    ) -> Difference? {
        was == isNow ? nil : Difference(name: name, was: json(was), isNow: json(isNow))
    }

    /// `configuration`'s keys and their values, each as sorted-keys JSON.
    static func values(of configuration: MuterConfiguration) -> [String: String] {
        guard let data = try? JSONEncoder().encode(configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object.compactMapValues { value in
            (try? JSONSerialization.data(withJSONObject: value, options: jsonOptions))
                .map { String(lossyUTF8: $0) }
        }
    }

    static func json<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(lossyUTF8: $0) }
    }

    static let jsonOptions: JSONSerialization.WritingOptions = [
        .sortedKeys,
        .fragmentsAllowed,
        .withoutEscapingSlashes,
    ]
}
