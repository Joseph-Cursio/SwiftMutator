import Foundation

/// What a resumed run carries from its results file to mutation testing. `file` stays open and locked until
/// SwiftMutator exits or mutation testing ends it, so no other run writes to the file meanwhile.
final class ResumeState: Equatable {
    /// The results file, found from what `--resume` named.
    let path: String
    /// The file, open to append the session to.
    let file: ResultsRecording
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

    init(
        path: String,
        file: ResultsRecording,
        recorded: RecordedResults,
        lastHeader: ResultsHeader,
        provenance: Provenance,
        forced: [String],
        notices: [String]
    ) {
        self.path = path
        self.file = file
        self.recorded = recorded
        self.lastHeader = lastHeader
        self.provenance = provenance
        self.forced = forced
        self.notices = notices
    }

    /// The number of the file's last session; this run's is the next.
    var lastSession: Int {
        recorded.headers.map(\.session).max() ?? 0
    }

    /// The same resume, as there is only ever one.
    static func == (lhs: ResumeState, rhs: ResumeState) -> Bool {
        lhs === rhs
    }
}
