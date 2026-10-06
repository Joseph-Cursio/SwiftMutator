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

        // A run stopped at once (a second Ctrl-C, SIGKILL, a crash) leaves its worker clones, even once `_mutated` is gone.
        let parent = mutated.deletingLastPathComponent().path
        let leftovers = ((try? fileManager.contentsOfDirectory(atPath: parent)) ?? [])
            .filter { Self.isWorkerClone($0, of: mutated.lastPathComponent) }
            .sorted()
        for name in leftovers {
            try remove((parent as NSString).appendingPathComponent(name))
        }
        return []
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
