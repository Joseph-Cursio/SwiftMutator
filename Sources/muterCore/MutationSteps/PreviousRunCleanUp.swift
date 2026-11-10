import Foundation

struct PreviousRunCleanUp: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let mutated = state.mutatedProjectDirectoryURL
        if fileManager.fileExists(atPath: mutated.path) {
            try remove(mutated.path)
        }

        // A run stopped at once (a second Ctrl-C, SIGKILL, a crash) leaves its worker clones, even once the copy is
        // gone, and the active-mutant files, helper links and xcodebuild derived data beside its folders. A link's
        // tests' `UserDefaults` go with it. So do the folders and files a SwiftMutator from before `.noindex` left
        // under the names it gave them, its copy `<project>_mutated` too, a hand fix in it included: this run holds
        // the lock that SwiftMutator took for them, `<project>_mutated.lock`, so none of them is in use. A run of one
        // mutant's stem is `<project>_mutant`, so it removes only what such runs left.
        let stem = MutatedProjectNames.stem(of: mutated)
        let parent = mutated.deletingLastPathComponent().path
        let leftovers = ((try? fileManager.contentsOfDirectory(atPath: parent)) ?? [])
            .filter { $0 != mutated.lastPathComponent && MutatedProjectNames.isLeftover($0, of: stem) }
            .sorted()
        for name in leftovers {
            try remove(parent.appendingPathComponent(name))
            if name.hasSuffix(DirectTestRun.helperLinkSuffix) {
                DirectTestRun.removeDefaultsDomain(name)
            }
        }
        return []
    }

    private func remove(_ path: String) throws {
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw MuterError.removeProjectFromPreviousRunFailed(
                reason: error.localizedDescription
            )
        }
    }
}
