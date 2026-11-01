import Foundation

/// `--since`: asks git, in the project, which Swift files changed since the merge base of the ref and HEAD, and with
/// `--changed-lines` which lines. Runs before a resume is checked, which compares the choice, and before the project
/// is copied, so a ref git doesn't know, or a change with no Swift file to mutate, ends the run before then.
struct SelectChangedCode: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.selectChanges)
    private var selectChanges: ChangeSelectionProbe

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let ref = state.runOptions.since else { return [] }
        let result = await selectChanges(ref, state.runOptions.changedLinesOnly, state.projectDirectoryURL)
        // A git that stopping the run killed reads as failed.
        try Task.checkCancellation()
        let selection = try result.get()
        events.send(.changesSelected(selection))

        guard !selection.files.isEmpty else {
            throw NothingToMutate(reason: .noSwiftFileChanged, selection: selection)
        }
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        guard selection.files.contains(where: { !isExcluded($0.path) }) else {
            throw NothingToMutate(reason: .everyFileExcluded(count: selection.files.count), selection: selection)
        }
        return [.changesSelected(selection)]
    }
}
