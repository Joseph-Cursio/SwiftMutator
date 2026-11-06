import Foundation

/// The names of the folders and files SwiftMutator makes beside a project: its copy, `<project>_mutated.noindex`, or
/// `<project>_mutant.noindex` for a run of one mutant; a clone of the copy per worker beyond the first,
/// `<project>_mutated_worker<n>.noindex`; and each worker's xcodebuild derived data,
/// `<project>_mutated.DerivedData.noindex` and `<project>_mutated_worker<n>.DerivedData.noindex`.
///
/// Every folder's name ends in `.noindex`, because Spotlight skips such a folder, and everything in it, while it would
/// otherwise index each copy, `.build` and all, as the run builds and writes into it. Spotlight goes only by the
/// folder's own name, so `.noindex` comes last: it would index `<project>_mutated.noindex_worker1`.
///
/// Every name starts with the folder's stem, its name without `.noindex`, so `*_mutated*` matches the names of a
/// `_mutated` copy, and `*_mutant*` those of a run of one mutant, which the first doesn't. The lock and the files
/// beside a folder are named after its stem, `<project>_mutated.lock` and
/// `<project>_mutated_worker<n>.active-mutant`, as SwiftMutators from before `.noindex` named them: an older
/// SwiftMutator and this one lock the same file for a project's copy, and a file an older one left has the name this
/// one gives it.
enum MutatedProjectNames {
    /// Ends the name of every folder SwiftMutator makes beside the project.
    static let unindexedSuffix = ".noindex"
    /// Follows the project's name in its copy's.
    static let copySuffix = "_mutated"
    /// Follows the project's name in the copy of a run of one mutant (`--mutant`).
    static let oneMutantCopySuffix = "_mutant"
    /// Follows a copy's stem, before the worker's number, in a clone's name.
    static let workerInfix = "_worker"
    /// Follows a worker's folder's stem in its derived data folder's name, before `.noindex`.
    static let derivedDataSuffix = ".DerivedData"
    /// Follows a worker's folder's stem in its activation markers' folder's name, before `.noindex`.
    static let activationSuffix = ".Activation"
    /// Follows a copy's stem in its lock file's name.
    static let lockSuffix = ".lock"

    /// The copy of `project`, beside it: `<project>_mutated.noindex`, or `<project>_mutant.noindex` for a run of one
    /// mutant. That run's copy, its lock and its clean-up are its own, so it never removes a test plan's copy, which
    /// may have been fixed by hand, and it can run while another run of the project tests.
    static func copy(of project: URL, forOneMutant: Bool) -> URL {
        let suffix = forOneMutant ? oneMutantCopySuffix : copySuffix
        return project.deletingLastPathComponent()
            .appendingPathComponent(project.lastPathComponent + suffix + unindexedSuffix)
    }

    /// The name of `folder` without `.noindex`: see `stem(_:)`.
    static func stem(of folder: URL) -> String {
        stem(folder.lastPathComponent)
    }

    /// `name` without `.noindex`, when it is a copy's or a clone's: when what is left ends in `_mutated`, `_mutant` or
    /// `_worker<n>`. Otherwise `name`, so that a copy a test plan names, which can be any folder, doesn't share its
    /// lock or files with something else of the same stem: `Scratch.noindex` locks `Scratch.noindex.lock`, not a
    /// user's `Scratch.lock`. A copy an older SwiftMutator named, `<project>_mutated`, is its own stem.
    static func stem(_ name: String) -> String {
        guard name.hasSuffix(unindexedSuffix) else { return name }
        let rest = String(name.dropLast(unindexedSuffix.count))
        return endsAsCopyOrClone(rest) ? rest : name
    }

    /// The file named `<stem><suffix>` beside `folder`, a copy or a clone.
    static func file(_ suffix: String, beside folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(stem(of: folder) + suffix)
    }

    /// Worker `worker`'s clone of `copy`, beside it: `<stem>_worker<n>.noindex`.
    static func clone(_ worker: Int, of copy: URL) -> URL {
        copy.deletingLastPathComponent()
            .appendingPathComponent(stem(of: copy) + workerInfix + "\(worker)" + unindexedSuffix)
    }

    /// Worker `worker`'s xcodebuild derived data folder, beside `copy`: `<stem>.DerivedData.noindex` for worker 0, and
    /// `<stem>_worker<n>.DerivedData.noindex` for worker n. An xcodebuild worker has no clone, but its derived data is
    /// named as if it had.
    static func derivedData(ofWorker worker: Int, in copy: URL) -> URL {
        let folder = stem(of: copy) + (worker == 0 ? "" : workerInfix + "\(worker)")
        return copy.deletingLastPathComponent()
            .appendingPathComponent(folder + derivedDataSuffix + unindexedSuffix)
    }

    /// The folder of the activation markers (`ActivationMarker`) of runs in `folder`, a copy or a clone, beside it:
    /// `<stem>.Activation.noindex`. Never in it, where a test that lists the package's files would see them. An
    /// xcodebuild worker has no clone, so its runs share the copy's.
    static func activationFolder(of folder: URL) -> URL {
        file(activationSuffix + unindexedSuffix, beside: folder)
    }

    /// The lock file of `copy`, beside it: `<stem>.lock`, so `<project>_mutated.lock` for both `<project>_mutated` and
    /// `<project>_mutated.noindex`.
    static func lockFile(of copy: URL) -> String {
        file(lockSuffix, beside: copy).path
    }

    /// Whether `name` is `<stem>_worker<n>`, a clone's stem.
    static func isWorkerClone(_ name: String, of stem: String) -> Bool {
        let prefix = stem + workerInfix
        guard name.hasPrefix(prefix) else { return false }
        return isNumber(name.dropFirst(prefix.count))
    }

    /// Whether `name`, beside the copy whose stem is `stem`, is something a run of that copy makes, other than the
    /// lock: the copy, a clone, a derived data or activation folder, under its name or under the one a SwiftMutator
    /// from before `.noindex` gave it, or an active-mutant file or helper link beside the copy or a clone. Never
    /// `<stem>.lock`, the log folder, or a name that only starts like these.
    static func isLeftover(_ name: String, of stem: String) -> Bool {
        if name.hasSuffix(unindexedSuffix) {
            return isFolder(String(name.dropLast(unindexedSuffix.count)), of: stem)
        }
        if isFolder(name, of: stem) { return true } // as an older SwiftMutator named it
        let fileSuffixes = [MutationTestingDelegate.activeMutantFileSuffix, DirectTestRun.helperLinkSuffix]
        guard let suffix = fileSuffixes.first(where: name.hasSuffix) else { return false }
        let folder = String(name.dropLast(suffix.count))
        return folder == stem || isWorkerClone(folder, of: stem)
    }

    /// Whether `name`, without `.noindex`, is the copy whose stem is `stem`, one of its clones, or the derived data or
    /// activation folder of one of its workers.
    private static func isFolder(_ name: String, of stem: String) -> Bool {
        let suffix = [derivedDataSuffix, activationSuffix].first(where: name.hasSuffix)
        let worker = String(name.dropLast(suffix?.count ?? 0))
        return worker == stem || isWorkerClone(worker, of: stem)
    }

    /// Whether `name` ends as a copy's or a clone's stem does: in `_mutated`, `_mutant` or `_worker<n>`.
    private static func endsAsCopyOrClone(_ name: String) -> Bool {
        if name.hasSuffix(copySuffix) || name.hasSuffix(oneMutantCopySuffix) { return true }
        guard let infix = name.range(of: workerInfix, options: .backwards) else { return false }
        return isNumber(name[infix.upperBound...])
    }

    private static func isNumber(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
