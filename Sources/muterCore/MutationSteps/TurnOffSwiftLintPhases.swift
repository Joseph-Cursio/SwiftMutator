import Foundation

/// Turns SwiftLint off in the build phases of the copy's Xcode projects, unless `keepSwiftLintPhases` keeps it, and
/// says which (`SwiftLintPhases`): never in the project itself. Every xcodebuild build of the copy runs them, the
/// coverage run, each build for testing and the baseline's included, though each mutated file turns every rule off.
/// Only for xcodebuild: a SwiftPM build has no build phases, and SwiftLint's build tool plugins are left as they are.
///
/// It runs right after `FingerprintProjectTree`, so the fingerprint holds the project's files as they are, and a run
/// that changes `keepSwiftLintPhases` resumes another's. Each run makes its copy afresh, and the commands it turned
/// off are found again and left as they are, so a copy is never changed twice. A run of a test plan copies nothing:
/// its copy has them off, or on, as `mutate-without-running` left them.
struct TurnOffSwiftLintPhases: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let configuration = state.muterConfiguration
        guard configuration.buildSystem == .xcodebuild, !configuration.keepsSwiftLintPhases else { return [] }
        let copy = state.mutatedProjectDirectoryURL
        let projectFiles = ProjectTree.walk(
            copy,
            keeping: SwiftLintPhases.isProjectFile,
            skippingCheckouts: false,
            pruning: FingerprintProjectTree.foldersWritten(in: copy, by: configuration)
        )
        let phases = projectFiles.sorted().reduce(SwiftLintPhases()) { phases, path in
            phases + SwiftLintPhases.turnOff(
                inProjectFileAt: copy.appendingPathComponent(path),
                shownAs: path.deletingLastPathComponent
            )
        }
        if !phases.isEmpty {
            events.send(.swiftLintPhasesTurnedOff(phases))
        }
        return []
    }
}
