import Foundation

/// `--since`: lists the paths discovery picks from, once the project is copied and before coverage is gathered, so a
/// change to code no target the tests reach compiles, as an example app's, an unused target's or a plugin's, ends the
/// run before the whole test suite runs for coverage. Discovery then picks from the same list. When a run with
/// coverage follows, a change to an Xcode project's file that its targets' listing left out goes on to the coverage
/// run, whose data may name it (`DiscoverSourceFiles.candidateWalk`): only the walk of the project ends that run here.
struct ListChangedSources: MutationStep {
    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let selection = state.changeSelection else { return [] }
        let candidates = try await DiscoverSourceFiles().listedCandidates(in: state)
        let coverageFollows = !state.runOptions.skipCoverage
        let checked = coverageFollows ? candidates.walk ?? candidates.paths : candidates.paths
        let listed = Set(checked.map(\.precomposedStringWithCanonicalMapping))
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        let kept = selection.files.filter { !isExcluded($0.path) }
        guard kept.contains(where: { listed.contains($0.path) }) else {
            throw NothingToMutate(reason: .noTargetCompiles(count: kept.count), selection: selection)
        }
        let narrowed = candidates.walk.map { $0.count != candidates.paths.count } ?? false
        return [.candidatePathsListed(candidates.paths)]
            + (narrowed ? [.candidateWalkListed(candidates.walk ?? [])] : [])
    }
}
