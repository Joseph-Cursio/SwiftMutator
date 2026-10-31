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

/// Lets a recursive copy continue past files that disappear after the copy has
/// enumerated them. Every other error, a permission failure included, still
/// stops the copy.
final class VanishedFileTolerance: NSObject, FileManagerDelegate {
    #if os(Linux)
    /// FoundationEssentials makes the delegate `Sendable`. The file manager calls it synchronously on the copying
    /// thread, and the paths are read only once the copy has returned.
    nonisolated(unsafe) private(set) var skippedPaths: [String] = []
    #else
    private(set) var skippedPaths: [String] = []
    #endif

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        shouldProceed(afterError: error, copying: srcPath)
    }

    private func shouldProceed(afterError error: Error, copying path: String) -> Bool {
        guard Self.isNoSuchFile(error) else {
            return false
        }

        skippedPaths.append(path)
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

#if os(Linux)
/// FoundationEssentials gives `FileManagerDelegate` no default implementations, so the rest of it is spelled out with
/// Darwin's defaults: every item is handled, and any other error stops the operation. Its `copyItem` asks only the URL
/// forms, so a file that vanishes is tolerated there too.
extension VanishedFileTolerance {
    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAt srcURL: URL,
        to dstURL: URL
    ) -> Bool {
        shouldProceed(afterError: error, copying: srcURL.path)
    }

    func fileManager(_ fileManager: FileManager, shouldCopyItemAtPath srcPath: String, toPath dstPath: String) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldMoveItemAtPath srcPath: String, toPath dstPath: String) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldMoveItemAt srcURL: URL, to dstURL: URL) -> Bool {
        true
    }

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        movingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        false
    }

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        movingItemAt srcURL: URL,
        to dstURL: URL
    ) -> Bool {
        false
    }

    func fileManager(_ fileManager: FileManager, shouldLinkItemAtPath srcPath: String, toPath dstPath: String) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldLinkItemAt srcURL: URL, to dstURL: URL) -> Bool {
        true
    }

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        linkingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        false
    }

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        linkingItemAt srcURL: URL,
        to dstURL: URL
    ) -> Bool {
        false
    }

    func fileManager(_ fileManager: FileManager, shouldRemoveItemAtPath path: String) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
        true
    }

    func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, removingItemAtPath path: String) -> Bool {
        false
    }

    func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, removingItemAt URL: URL) -> Bool {
        false
    }
}
#endif
