import Foundation

extension MuterConfiguration {
    /// `reports`, with each relative path resolved against `folder`, the project's: what a run saves; none without the
    /// key.
    func reportRequests(in folder: URL) -> [ReportRequest] {
        (reports ?? []).map { $0.resolved(in: folder.path) }
    }

    /// One control run for each 100 mutants costs about 3% of a run: a control run takes as long as a survivor, which
    /// on SwiftProjectLint on 31 October took 6.9 s, against 2.4 s for a mutant on average.
    static let defaultMutantsPerControlRun = 100

    /// How many mutants are tested for each control run: `controlRunEvery`, or the default; 0 for none.
    var mutantsPerControlRun: Int {
        controlRunEvery ?? Self.defaultMutantsPerControlRun
    }

    /// Enough to judge many suspect tests, at `PerformMutationTesting.rerunsForEachSuspectTest` each. A rerun takes as
    /// long as a survivor's run, so on SwiftProjectLint's 6.9 s the most this adds is about 12 minutes to about 8
    /// hours.
    static let defaultSuspectKillReruns = 100

    /// How many kills a run tests again alone: `suspectKillReruns`, or the default; 0 for none.
    var killsToTestAgainAlone: Int {
        suspectKillReruns ?? Self.defaultSuspectKillReruns
    }

    /// As many survivors as `defaultSuspectKillReruns` has kills tested again: each costs up to
    /// `propertySurvivorReruns` runs of the property tests alone, which are a share of the suite.
    static let defaultPropertySurvivorRerunLimit = 100

    /// How many times each survivor is tested again with the property tests: `propertySurvivorReruns`; 0 for none.
    var runsForEachSurvivor: Int {
        propertySurvivorReruns ?? 0
    }

    /// How many survivors a run tests again with the property tests: `propertySurvivorRerunLimit`, or the default;
    /// 0 for none.
    var survivorsToTestAgain: Int {
        propertySurvivorRerunLimit ?? Self.defaultPropertySurvivorRerunLimit
    }

    /// Whether every mutant's test run keeps its log: only when `keepAllLogs` is `enabled`.
    var keepsAllLogs: Bool {
        keepAllLogs == .enabled
    }

    /// Whether the copy's build phases keep running SwiftLint: only when `keepSwiftLintPhases` is `enabled`.
    var keepsSwiftLintPhases: Bool {
        keepSwiftLintPhases == .enabled
    }

    /// When a test is suspect, from `suspectTestFilePercent` and `suspectTestMinimumFiles`.
    var suspectTestThresholds: SuspectTestThresholds {
        SuspectTestThresholds(
            filePercent: suspectTestFilePercent ?? SuspectTestThresholds.standard.filePercent,
            minimumFiles: suspectTestMinimumFiles ?? SuspectTestThresholds.standard.minimumFiles
        )
    }

    /// Why `propertyTestFilter` can't be used with this configuration; nil when it can, or isn't set. It names the
    /// flags too, which give the keys' values when given.
    var propertyRerunsUnsupportedReason: String? {
        guard propertyTestFilter != nil else { return nil }
        if propertyTests?.isEmpty != false {
            return "propertyTestFilter (or --property-test-filter) needs propertyTests or --property-tests too, which "
                + "say which of a kill's recorded tests are property tests"
        }
        if buildSystem == .unknown {
            return "propertyTestFilter (or --property-test-filter) needs a SwiftPM or xcodebuild project, whose test "
                + "command it can filter"
        }
        return nil
    }

    /// Why `propertySurvivorReruns` can't be used with this configuration; nil when it can, or tests none again.
    var propertySurvivorRerunsUnsupportedReason: String? {
        guard runsForEachSurvivor > 0, propertyTestFilter?.isEmpty != false else { return nil }
        return "propertySurvivorReruns (or --property-survivor-reruns) needs propertyTestFilter or "
            + "--property-test-filter, which selects the property tests to run again"
    }
}
