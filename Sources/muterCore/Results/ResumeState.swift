import Foundation

/// What a resumed run carries from its results file to mutation testing, or a run that reuses an earlier run's results
/// (`--reuse`). A resume's `file` stays open and locked until SwiftMutator exits or mutation testing ends it, so no
/// other run writes to the file meanwhile. The steps run one after another, so one step at a time uses `file`:
/// `LoadResumeState` opens it, and mutation testing writes to it only through `TestingSession`, behind its lock, and
/// closes it once the session is over. A reuse reads its file once, and writes a results file of its own: it holds only
/// shared locks on the earlier run's log folders (`reusedFolders`), which it copies kept logs from later.
final class ResumeState: Equatable, @unchecked Sendable { // `file` is used by one step at a time
    /// The results file, found from what `--resume` or `--reuse` named.
    let path: String
    /// A resume's file, open to append the session to; nil for a reuse.
    let file: ResultsRecording?
    /// What the file recorded when the run started.
    let recorded: RecordedResults
    /// The header of the file's last session, which this run was compared with.
    let lastHeader: ResultsHeader
    /// Probed once, before the copy, then written in the session's header: what was checked is what is recorded.
    let provenance: Provenance
    /// The build and toolchain differences `--force-resume` let through, by their names in the header's `provenance`.
    let forced: [String]
    /// A sentence for each change no result depends on.
    let notices: [String]
    /// A reuse's shared locks on the earlier run's log folders, held as long as the state is, so no run prunes them
    /// before their logs are copied; nil for a resume, whose `file` is locked.
    let reusedFolders: ReusedFolders?

    init(
        path: String,
        file: ResultsRecording?,
        recorded: RecordedResults,
        lastHeader: ResultsHeader,
        provenance: Provenance,
        forced: [String],
        notices: [String],
        reusedFolders: ReusedFolders? = nil
    ) {
        self.path = path
        self.file = file
        self.recorded = recorded
        self.lastHeader = lastHeader
        self.provenance = provenance
        self.forced = forced
        self.notices = notices
        self.reusedFolders = reusedFolders
    }

    /// Whether the run reuses the file's results in a results file of its own, rather than resuming the file's run.
    var isReuse: Bool {
        file == nil
    }

    /// The number of the file's last session; a resumed run's is the next.
    var lastSession: Int {
        recorded.headers.map(\.session).max() ?? 0
    }

    /// The same resume, as there is only ever one.
    static func == (lhs: ResumeState, rhs: ResumeState) -> Bool {
        lhs === rhs
    }
}
