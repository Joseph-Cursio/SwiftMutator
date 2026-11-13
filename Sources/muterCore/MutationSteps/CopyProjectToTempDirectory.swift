import Foundation

class CopyProjectToTempDirectory: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.process)
    private var process: ProcessFactory

    /// `ModuleCache` from the native build system, `ModuleCache.noindex` from Swift Build (`.build/out`).
    /// Swift Build's other precompiled-module folders survive a copy; only this one is path-bound.
    static let moduleCacheDirectoryNames = ["ModuleCache", "ModuleCache.noindex"]

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        do {
            events.send(.projectCopyStarted)

            // The project is live while it is copied: build tools create and
            // delete lock and temporary files under `.build` at any moment, and
            // one vanishing mid-copy used to abort the whole run. The shared
            // file manager's delegate is restored afterwards.
            var manager = fileManager
            let previousDelegate = manager.delegate
            let tolerance = VanishedFileTolerance()
            manager.delegate = tolerance
            defer { manager.delegate = previousDelegate }

            // `delegate` is weak, and `tolerance` isn't used after this, so its lifetime
            // is extended explicitly to cover the copy.
            try withExtendedLifetime(tolerance) {
                try manager.copyItem(
                    atPath: state.projectDirectoryURL.path,
                    toPath: state.mutatedProjectDirectoryURL.path
                )
            }

            if !tolerance.skippedPaths.isEmpty {
                events.send(.projectCopySkippedVanishedFiles(tolerance.skippedPaths))
            }

            await discardModuleCaches(in: state.mutatedProjectDirectoryURL)

            events.send(.projectCopyFinished(destinationPath: state.mutatedProjectDirectoryURL.path))

            return []
        } catch {
            throw MuterError.projectCopyFailed(
                reason: error.localizedDescription
            )
        }
    }

    /// Clang module caches record the absolute path they were built under. Copied alongside the rest of
    /// a project's build directory they no longer match where they now live, and every compile in the
    /// copy fails with `precompiled file … was compiled with module cache path …` followed by
    /// `missing required module 'SwiftShims'`. Discarding them keeps the rest of the build directory
    /// warm — the compiler rebuilds the caches in place on the next compile.
    private func discardModuleCaches(in directory: URL) async {
        let caches = await process()
            .find(atPath: directory.path, byNames: Self.moduleCacheDirectoryNames)?
            .split(separator: "\n")
            .map(String.init) ?? []

        for cache in caches {
            try? fileManager.removeItem(atPath: cache)
        }
    }
}
