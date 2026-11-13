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

    /// Why a mutant's test run can't be stopped at its first failed test with this test command, or nil.
    var stopAtFirstFailureUnsupportedReason: String? {
        if buildSystem != .swift {
            return "it works only for `swift test` (set `buildSystem: swift` if `executable` wraps it); "
                + "other test commands run tests where SwiftMutator can't stop them"
        }
        if testCommandArguments.contains(where: { $0.hasPrefix("--repeat-until") }) {
            return "the test arguments retry failing tests (--repeat-until), so a failure doesn't decide the run"
        }
        return nil
    }

    /// Whether mutants' test runs stop at their first failed test: unless `stopAtFirstFailure` is `disabled`,
    /// whenever this test command supports it and failed-test lines are reliable. Baselines never do.
    /// On by default since an A/B run on SwiftProjectLint (255 mutants, 4 workers) took 37% less time and
    /// the switch changed no mutant's verdict. A mutant that both fails a test and crashes can be reported
    /// killed by a test failure rather than by a runtime error, depending on which comes first.
    var stopsAtFirstFailure: Bool {
        stopAtFirstFailureUnsupportedReason == nil && failedTestLinesAreReliable && stopAtFirstFailure != .disabled
    }

    /// Why `propertyTestFilter` can't be used with this configuration; nil when it can, or isn't set.
    var propertyRerunsUnsupportedReason: String? {
        guard propertyTestFilter != nil else { return nil }
        if propertyTests?.isEmpty != false {
            return "propertyTestFilter needs propertyTests too, which say which of a kill's recorded tests are "
                + "property tests"
        }
        if buildSystem == .unknown {
            return "propertyTestFilter needs a SwiftPM or xcodebuild project, whose test command it can filter"
        }
        return nil
    }
}
