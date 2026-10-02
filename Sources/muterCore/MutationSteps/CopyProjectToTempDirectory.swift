import Foundation

class CopyProjectToTempDirectory: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.process)
    private var process: ProcessFactory

    private let moduleCacheDirectoryName = "ModuleCache"

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        do {
            notificationCenter.post(
                name: .projectCopyStarted,
                object: nil
            )

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
                notificationCenter.post(
                    name: .projectCopySkippedVanishedFiles,
                    object: tolerance.skippedPaths
                )
            }

            discardModuleCaches(in: state.mutatedProjectDirectoryURL)

            notificationCenter.post(
                name: .projectCopyFinished,
                object: state.mutatedProjectDirectoryURL.path
            )

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
    private func discardModuleCaches(in directory: URL) {
        let caches = process()
            .find(atPath: directory.path, byName: moduleCacheDirectoryName)?
            .split(separator: "\n")
            .map(String.init) ?? []

        for cache in caches {
            try? fileManager.removeItem(atPath: cache)
        }
    }
}

/// Lets a recursive copy continue past files that disappear after the copy has
/// enumerated them. Every other error, a permission failure included, still
/// stops the copy.
final class VanishedFileTolerance: NSObject, FileManagerDelegate {
    private(set) var skippedPaths: [String] = []

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        guard Self.isNoSuchFile(error) else {
            return false
        }

        skippedPaths.append(srcPath)
        return true
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isNoSuchFile(underlying)
            }
            return false
        }
    }
}
