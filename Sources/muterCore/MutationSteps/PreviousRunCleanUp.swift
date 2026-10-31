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

        // A run stopped at once (a second Ctrl-C, SIGKILL, a crash) leaves its worker clones, even once `_mutated` is
        // gone, and the active-mutant files and helper links beside its folders. A link's tests' `UserDefaults` go
        // with it.
        let parent = mutated.deletingLastPathComponent().path
        let leftovers = ((try? fileManager.contentsOfDirectory(atPath: parent)) ?? [])
            .filter { Self.isLeftover($0, of: mutated.lastPathComponent) }
            .sorted()
        for name in leftovers {
            try remove((parent as NSString).appendingPathComponent(name))
            if name.hasSuffix(DirectTestRun.helperLinkSuffix) {
                DirectTestRun.removeDefaultsDomain(name)
            }
        }
        return []
    }

    /// A worker clone, or the active-mutant file or helper link beside the mutated project or a clone, as
    /// `MutationTestingDelegate.activeMutantFile(forWorkerIn:)` and `DirectTestRun.helperLink(forWorkerIn:)` name them.
    static func isLeftover(_ name: String, of mutatedName: String) -> Bool {
        let suffixes = [MutationTestingDelegate.activeMutantFileSuffix, DirectTestRun.helperLinkSuffix]
        guard let suffix = suffixes.first(where: name.hasSuffix) else { return isWorkerClone(name, of: mutatedName) }
        let folder = String(name.dropLast(suffix.count))
        return folder == mutatedName || isWorkerClone(folder, of: mutatedName)
    }

    /// `<mutated>_worker<n>`, as `PerformMutationTesting.cloneMutatedProject` names a clone.
    static func isWorkerClone(_ name: String, of mutatedName: String) -> Bool {
        let prefix = mutatedName + "_worker"
        guard name.hasPrefix(prefix) else { return false }
        let number = name.dropFirst(prefix.count)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
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
