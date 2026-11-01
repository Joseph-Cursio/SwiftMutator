import Foundation

/// `--since`: lists the paths discovery picks from, once the project is copied and before coverage is gathered, so a
/// change to code no target compiles, as an example app's or a plugin's, ends the run before the whole test suite runs
/// for coverage. Discovery then picks from the same list.
struct ListChangedSources: MutationStep {
    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let selection = state.changeSelection else { return [] }
        let paths = try await DiscoverSourceFiles().candidatePaths(in: state)
        let listed = Set(paths.map(\.precomposedStringWithCanonicalMapping))
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        let kept = selection.files.filter { !isExcluded($0.path) }
        guard kept.contains(where: { listed.contains($0.path) }) else {
            throw NothingToMutate(reason: .noTargetCompiles(count: kept.count), selection: selection)
        }
        return [.candidatePathsListed(paths)]
    }
}
