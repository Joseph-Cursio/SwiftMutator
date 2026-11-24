extension MutationTestObserver {
    /// What discovery's warnings and notices say: what it couldn't tell, so looked at more widely, and what it left
    /// out.
    func handleDiscoveryNoticeEvent(_ event: RunEvent) {
        switch event {
        case let .packageSourceFilesUnavailable(reason): logger.packageSourceFilesUnavailable(reason: reason)

        case let .xcodeTargetSourcesUnavailable(reason): logger.xcodeTargetSourcesUnavailable(reason: reason)

        case let .coveredFilesNotWalked(files): logger.coveredFilesNotWalked(files)

        case let .filesToMutateUnmatched(entries): logger.filesToMutateUnmatched(entries)

        case let .buildConditionsUnavailable(reason): logger.buildConditionsUnavailable(reason: reason)

        default:
            break
        }
    }
}
