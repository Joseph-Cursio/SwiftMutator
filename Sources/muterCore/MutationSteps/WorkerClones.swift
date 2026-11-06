import Foundation

/// The clones of the mutated project that a SwiftPM run's workers beyond the first test in, made before its mutants
/// and removed after them.
extension PerformMutationTesting {
    struct WorkerDirectoryError: Error, CustomStringConvertible {
        let clone: URL
        /// cp's exit status, or nil if it couldn't be started.
        let status: Int32?
        /// The first line cp wrote to standard error, such as why a file couldn't be copied.
        var error: String?

        var description: String {
            let copy = status.map { "cp exited \($0)" } ?? "cp could not be started"
            let why = error.map { ": \($0)" } ?? ""
            return "SwiftMutator could not clone the mutated project to \(clone.path) "
                + "for a parallel worker (\(copy))\(why)."
        }
    }

    /// One clone of `project` per extra worker, next to it as `<stem>_worker<n>.noindex`
    /// (`MutatedProjectNames.clone(_:of:)`). On macOS `cp -c`
    /// clones on APFS, so even a large build directory copies in seconds. Each clone is then built once
    /// before testing (`buildWorkerDirectories`). Every path in it has changed, so that is a full build:
    /// about one baseline build of time, and much of the clone's build directory is rewritten rather
    /// than shared. Its copied Clang module caches record the mutated project's path, so they're
    /// discarded first, as `CopyProjectToTempDirectory` does for the mutated project itself.
    static func cloneMutatedProject(_ project: URL, count: Int) async throws -> [URL] {
        try await cloneMutatedProject(project, count: count, copying: copyProject(_:to:))
    }

    /// `copy` copies the project to one clone. If one fails, the clones made before it are removed, and so is whatever
    /// the failed copy left, rather than staying beside the project until SwiftMutator next starts.
    static func cloneMutatedProject(
        _ project: URL,
        count: Int,
        copying copy: (_ project: URL, _ clone: URL) async throws -> Void
    ) async throws -> [URL] {
        guard count > 0 else { return [] }
        var clones: [URL] = []
        do {
            for index in 1...count {
                let clone = MutatedProjectNames.clone(index, of: project)
                try? FileManager.default.removeItem(at: clone)
                clones.append(clone) // before the copy, which can fail partway through
                try await copy(project, clone)
                discardModuleCaches(in: clone)
            }
            return clones
        } catch {
            removeClones(clones)
            throw error
        }
    }

    private static func copyProject(_ project: URL, to clone: URL) async throws {
        #if os(macOS)
        let copy = await Foundation.Process().runCommand(
            url: "/bin/cp",
            arguments: ["-c", "-R", project.path, clone.path]
        )
        guard let copy, copy.status == 0 else {
            let error = copy?.errors.split(separator: "\n").first.map(String.init)
            throw WorkerDirectoryError(clone: clone, status: copy?.status, error: error)
        }
        #else
        try FileManager.default.copyItem(at: project, to: clone)
        #endif
    }

    static func discardModuleCaches(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        else { return }

        for case let url as URL in enumerator
            where CopyProjectToTempDirectory.moduleCacheDirectoryNames.contains(url.lastPathComponent) {
            // On Darwin, skipping the descendants of anything but a directory skips the next directory.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes each clone, the active-mutant file, helper link and activation folder beside it, and its tests'
    /// `UserDefaults`, on a thread of its own: one large clone takes a
    /// fraction of a second or more to remove, and a run that is stopping does this last, when a second signal exits
    /// at once and leaves the rest behind.
    static func removeClones(_ directories: [URL]) {
        DispatchQueue.concurrentPerform(iterations: directories.count) { index in
            let clone = directories[index]
            try? FileManager.default.removeItem(at: MutationTestingDelegate.activeMutantFile(forWorkerIn: clone))
            try? FileManager.default.removeItem(at: MutatedProjectNames.activationFolder(of: clone))
            DirectTestRun.removeOwnDefaults(forWorkerIn: clone)
            try? FileManager.default.removeItem(at: clone)
        }
    }
}
