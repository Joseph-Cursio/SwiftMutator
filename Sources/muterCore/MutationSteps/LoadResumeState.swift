import Foundation

/// Opens and locks the results file of the stopped run that `--resume` continues, and checks that this run would
/// reproduce its results. It runs before the last run's copy is removed and the project copied, so every refusal comes
/// first, in one message: a run still writing the file, a changed configuration or selection of mutants, a changed
/// SwiftMutator build or toolchain that `--force-resume` didn't let through, an `-o` that would replace the file, and
/// changed project files that no `--resume-ignoring` glob matches. The project's files are fingerprinted in the
/// project itself, as there is no copy yet; `FingerprintProjectTree` checks the copy again.
///
/// For `--reuse` it reads the earlier run's results file once, without a lock: the new run writes a file of its own,
/// and a run of the same project still writing it holds the project's copy, which `LockMutatedProject` refuses. The
/// same checks apply, with `--force-reuse` for `--force-resume`, except changed files: they don't refuse a reuse, but
/// decide which results it keeps, once `FingerprintProjectTree` has listed them in the copy.
struct LoadResumeState: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.resultsFiles)
    private var resultsFiles: ResultsFileOpening
    @Dependency(\.provenance)
    private var provenance: ProvenanceProbe
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let continuedURL = state.runOptions.continuedFrom else { return [] }
        let path = try ResultsFile.find(at: continuedURL.path, using: fileManager)
        if state.runOptions.isReuse {
            return try await [.resumeStateLoaded(check(nil, at: path, against: state))]
        }
        let file: ResultsRecording
        do {
            file = try resultsFiles.openForResume(at: path)
        } catch ResultsFileError.inUse {
            // flock can't name its holder; the process that wrote the last session most likely holds it.
            let last = fileManager.contents(atPath: path)
                .flatMap { try? RecordedResults.read($0, path: path) }?
                .headers.last?.provenance
            throw ResumeRefused(
                path: path,
                reasons: [.inUse(lastProcess: last?.processIdentifier, lastHost: last?.host)],
                beforeTheCopy: true
            )
        }
        do {
            let resume = try await check(file, at: path, against: state)
            // The command that continues a run names its merge base, which the run's reports go on calling by its ref.
            if let recorded = resume.lastHeader.since, let selection = state.changeSelection,
               recorded.mergeBase == selection.mergeBase {
                let named = selection.named(recorded.ref, commit: recorded.commit)
                return [.resumeStateLoaded(resume), .changesSelected(named)]
            }
            return [.resumeStateLoaded(resume)]
        } catch {
            // The lock goes with a refusal, or a file that can't be resumed, rather than when SwiftMutator exits.
            file.close()
            throw error
        }
    }

    /// The resume of the run that `file`, at `path`, recorded, once it is checked against `state`'s run: refused unless
    /// this run would reproduce the recorded results. A reuse has no `file`.
    private func check(
        _ file: ResultsRecording?,
        at path: String,
        against state: AnyMutationTestState
    ) async throws -> ResumeState {
        let options = state.runOptions
        guard let data = fileManager.contents(atPath: path) else {
            throw ResultsFileError.unreadable(path: path)
        }
        // Refuses a file a newer SwiftMutator wrote, and one without a header.
        let recorded = try RecordedResults.read(data, path: path)
        guard let lastHeader = recorded.headers.last else {
            throw ResultsFileError.notAResultsFile(path: path)
        }
        // Asked in the project, where swiftly finds the same `.swift-version` as in the copy.
        let current = await provenance(state.muterConfiguration)
        // Only a resume refuses changed files, so only a resume fingerprints the project here.
        var tree: ProjectTree?
        if file != nil {
            tree = await ProjectTree.fingerprint(
                listingIn: state.projectDirectoryURL,
                hashingIn: state.projectDirectoryURL,
                excluding: ProjectTree.excludedPaths(options, under: state.projectDirectoryURL)
                    + (lastHeader.project?.excluded ?? []),
                list: listProjectFiles
            )
        }
        // A probe or a git that stopping the run killed would read as a changed toolchain, or as removed files.
        try Task.checkCancellation()

        let verdict = ResumeCheck.compare(
            lastHeader,
            with: ResumeCheck.Current(state: state, provenance: current),
            forcing: options.forceResume,
            reusing: file == nil
        )
        var reasons = verdict.refusals
        if let reportPath = options.reportOptions.path, ResultsFile.isSameFile(reportPath, path) {
            reasons.append(.reportWouldReplaceTheResultsFile(reportPath))
        }
        if let recordedTree = lastHeader.project, let tree {
            let unwaived = tree.changes(since: recordedTree).partition(by: options.resumeIgnoring).unwaived
            if !unwaived.isEmpty {
                reasons.append(.filesChanged(unwaived))
            }
        }
        guard reasons.isEmpty else {
            throw ResumeRefused(path: path, reasons: reasons, beforeTheCopy: true, isReuse: file == nil)
        }
        return ResumeState(
            path: path,
            file: file,
            recorded: recorded,
            lastHeader: lastHeader,
            provenance: current,
            forced: verdict.forced,
            notices: verdict.notices
        )
    }
}
