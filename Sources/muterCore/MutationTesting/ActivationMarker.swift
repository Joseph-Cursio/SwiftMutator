import Foundation

/// The files that show whether a mutant's code ran in its test run: `<folder>/<hash of its ID>`, which the generated
/// code creates once the mutant's block runs, and the same name with `reachedSuffix`, created once the run reads any
/// mutated file's switches.
///
/// A run with neither shows nothing: it can't be told from a test host that can't write there, as a sandboxed one
/// can't, or a test command that dropped the path. Only `reached` without the marker says the mutant's block didn't
/// run, so a host that can't write keeps the verdicts it would have had (`TestRun.activated`). One limit: `reached`
/// shows only that some process of the run could write, so a run whose unhosted tests can write, and whose mutant ran
/// only in a sandboxed test host, reads as not having run it.
///
/// The marker covers the statement list the mutant's switch wraps, so `true` says that block was entered, not that the
/// mutated expression ran: an early return can leave a marked mutant unrun. `false` is the one strong signal.
///
/// One name per mutant, and per xcodebuild worker, whose runs share a folder and may test a repeated mutant, with one
/// ID, at once. Not per run: an `.xctestrun`, which holds the path, is written once per job, while a run the simulator
/// failed to launch runs twice. A process left over from an earlier run marks only its own mutant.
struct ActivationMarker: Equatable {
    /// Follows the marker's name in the name of the file that shows the run reached mutated code.
    static let reachedSuffix = ".reached"

    /// The file the generated code creates when the mutant's block runs.
    let path: String

    /// The file the generated code creates when the run reads any mutated file's switches.
    var reachedPath: String {
        path + Self.reachedSuffix
    }

    /// The marker of `schema`'s mutant for a worker's folder, the mutated project or a clone, and for an xcodebuild
    /// worker, the `.xctestrun` file its runs test from. A hash, as an ID holds its file's name, and a long enough one
    /// would pass the limit on a file's name, and fail to write.
    init(of schema: MutationSchema, forWorkerIn folder: URL, testRunFile: String? = nil) {
        path = MutatedProjectNames.activationFolder(of: folder)
            .appendingPathComponent((schema.id + (testRunFile ?? "")).stableHash).path
    }
}
