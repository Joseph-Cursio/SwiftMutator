extension CoverageSummary {
    /// The summary of `coverage`; nil when the run has none, as when coverage couldn't be gathered.
    init?(_ coverage: Coverage) {
        guard coverage != .null else { return nil }
        self.init(percent: coverage.percent, filesWithoutCoverage: coverage.filesWithoutCoverage)
    }
}
