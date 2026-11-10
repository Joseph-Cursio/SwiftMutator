import Foundation
import SwiftSyntax

/// The run's results file: a header once the baseline passes, or at once for a resumed run with nothing left to test,
/// a line for each tested mutant as it finishes, and an end line however mutation testing ends.
extension PerformMutationTesting {
    /// Creates the results file in the run's log folder, and writes `header` to it. Without one the run goes on: the
    /// report at the end doesn't need it. A state without a log folder, which a test that bypasses the handler
    /// makes, writes none, and the header isn't made.
    ///
    /// A resumed run instead writes `header`, then a `retired` line of the `retiring` keys, to the stopped run's file,
    /// which it opened before the copy. Once both are written, it leaves a note naming the file in its own log folder,
    /// and announces the file. It is attached to the session only now: before its header, no line of the session's
    /// would belong to one. A run that reuses an earlier run's results writes a new file, as a first session does,
    /// with the `copying` results after its header, all at once, and copies their logs into its log folder, before it
    /// announces the file.
    ///
    /// The file becomes the session's as its first lines, the header and any `retired` line, are written, in one write
    /// while the session's lock is held. A stop at once then ends the session after both, or, before them, writes
    /// nothing, and a run killed as it starts leaves both or neither, unless the write is cut short, which leaves a
    /// cut-off last line that readers skip. Written one after the other, a kill or an end line between them would leave
    /// the header without the `retired` line, and the file would stand by the results the session retires until the
    /// next session's. `header` probes the toolchain, so it is made before any of this.
    func startResults(
        _ header: @autoclosure () async -> ResultsHeader,
        retiring retired: [MutantKey],
        copying reused: [Int: MutantResult],
        in session: TestingSession,
        state: AnyMutationTestState
    ) async {
        // A stop from now on is the results file's, which says it in its end line. One already recorded as a stop
        // before the first mutant, at once from the signal's thread, has its file: the run is about to exit.
        guard stoppedRun.resultsStart() else { return }
        if let resume = state.resumeState, let file = resume.file {
            var firstLines: [any Encodable] = [await header()]
            // Without it, the file would still stand by the earlier results this session doesn't keep.
            if !retired.isEmpty {
                firstLines.append(ResultsRetired(session: session.number, keys: retired))
            }
            guard sayingAFailure(session.startResults(in: file, writing: firstLines), in: session) else { return }
            session.header = firstLines.first as? ResultsHeader
            session.resultsPath = resume.path
            leaveANote(pointingTo: resume.path, session: session.number, in: state.loggingDirectory)
            events.send(.resultsFileCreated(path: resume.path))
            return
        }
        let loggingDirectory = state.loggingDirectory
        guard !loggingDirectory.isEmpty else { return }
        let headerLine = await header()
        do {
            let results = try resultsFiles.create(in: loggingDirectory)
            guard sayingAFailure(session.startResults(in: results, writing: [headerLine]), in: session) else { return }
            session.header = headerLine
            session.resultsPath = results.path
            if let resume = state.resumeState, resume.isReuse {
                let lines = reused.sorted { $0.key < $1.key }.map(\.value)
                guard sayingAFailure(session.append(contentsOf: lines), in: session) else { return }
                copyLogs(of: lines, from: resume, into: loggingDirectory)
            }
            events.send(.resultsFileCreated(path: results.path))
        } catch {
            events.send(.resultsFileUnavailable(reason: "\(error)"))
        }
    }

    /// Leaves a note in this session's log folder, `ResultsFile.noteFileName`, that names the results file at `path` it
    /// adds to, which is in the first session's folder, so that the folder can be given in the file's place. A state
    /// without a log folder leaves none. A note that can't be written is left out: the console names the file too.
    private func leaveANote(pointingTo path: String, session: Int, in loggingDirectory: String) {
        guard !loggingDirectory.isEmpty else { return }
        _ = fileManager.createFile(
            atPath: loggingDirectory.appendingPathComponent(ResultsFile.noteFileName),
            contents: Data(ResultsFile.note(pointingTo: path, session: session).utf8),
            attributes: nil
        )
    }

    /// Copies each of the `reused` results' kept logs from the folder of the session that recorded it in `resume`'s
    /// file into `loggingDirectory`, under the same name, which its new line names. A result whose recorded or new line
    /// names no log copies none, and a log that isn't there any more, or can't be copied, is left out: the result
    /// doesn't depend on it.
    private func copyLogs(of reused: [MutantResult], from resume: ResumeState, into loggingDirectory: String) {
        let folders = Dictionary(
            resume.recorded.headers.map { ($0.session, $0.logDirectory) }
        ) { _, last in last }
        for result in reused {
            guard let recorded = resume.recorded.latest[result.key], let folder = folders[recorded.session],
                  let name = recorded.log, let destinationName = result.log
            else { continue }
            let source = folder.appendingPathComponent(name)
            let destination = loggingDirectory.appendingPathComponent(destinationName)
            try? fileManager.copyItem(atPath: source, toPath: destination)
        }
    }

    /// Writes the session's end line, and closes its results file, which releases the file's lock.
    func endResults(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        testDuration: TimeInterval,
        detail: String? = nil
    ) {
        let written = session.end { recorded in
            ResultsEnd(
                session: session.number,
                endedAt: now(),
                reason: reason,
                detail: detail,
                testDurationSeconds: testDuration,
                recorded: recorded
            )
        }
        sayingAFailure(written, in: session)
    }
}
