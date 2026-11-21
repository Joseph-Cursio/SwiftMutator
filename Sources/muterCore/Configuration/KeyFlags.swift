/// The flags for the configuration keys that had none before #262's last part, as the command line gives them:
/// `--exclude-calls`' entries, which are added to `excludeCalls`, as `--exclude`'s are to `exclude`, and each other
/// flag's value, in place of its key's (`MuterConfiguration.overriding(...)`). A value is nil, or `unset` for an on/off
/// pair such as `--keep-all-logs` and `--no-keep-all-logs`, when its flag wasn't given, which leaves the key's.
struct KeyFlags: Equatable, Sendable {
    /// `--exclude-calls`: entries added to `excludeCalls` for this run.
    var excludeCalls: [String] = []
    /// `--coverage-threshold`, in place of `coverageThreshold`.
    var coverageThreshold: Double?
    /// `--build-system`, in place of `buildSystem`.
    var buildSystem: BuildSystem?
    /// `--stop-at-first-failure` or `--no-stop-at-first-failure`, in place of `stopAtFirstFailure`.
    var stopAtFirstFailure: ConfigurationSwitch = .unset
    /// `--workers-share-build` or `--no-workers-share-build`, in place of `workersShareBuild`.
    var workersShareBuild: ConfigurationSwitch = .unset
    /// `--one-worker-simulator` or `--no-one-worker-simulator`, in place of `oneWorkerSimulator`.
    var oneWorkerSimulator: ConfigurationSwitch = .unset
    /// `--suspect-test-file-percent`, in place of `suspectTestFilePercent`.
    var suspectTestFilePercent: Int?
    /// `--suspect-test-minimum-files`, in place of `suspectTestMinimumFiles`.
    var suspectTestMinimumFiles: Int?
    /// `--control-run-every`, in place of `controlRunEvery`.
    var controlRunEvery: Int?
    /// `--suspect-kill-reruns`, in place of `suspectKillReruns`.
    var suspectKillReruns: Int?
    /// `--keep-all-logs` or `--no-keep-all-logs`, in place of `keepAllLogs`.
    var keepAllLogs: ConfigurationSwitch = .unset
    /// `--keep-log-folders`, in place of `keepLogFolders`.
    var keepLogFolders: Int?
    /// `--keep-swiftlint-phases` or `--no-keep-swiftlint-phases`, in place of `keepSwiftLintPhases`.
    var keepSwiftLintPhases: ConfigurationSwitch = .unset
    /// `--property-test-filter`'s entries, in place of `propertyTestFilter`'s; nil when none was given.
    var propertyTestFilter: [String]?
    /// `--property-survivor-reruns`, in place of `propertySurvivorReruns`.
    var propertySurvivorReruns: Int?
    /// `--property-survivor-rerun-limit`, in place of `propertySurvivorRerunLimit`.
    var propertySurvivorRerunLimit: Int?
}

extension ConfigurationSwitch {
    /// What an on/off flag pair gives: `enabled` for the plain flag, `disabled` for its `--no-` form, and `unset` when
    /// neither is given.
    static func given(_ flag: Bool?) -> Self { // swiftlint:disable:this discouraged_optional_boolean
        flag.map { $0 ? .enabled : .disabled } ?? .unset
    }

    /// This switch, or `other` when it is `unset`.
    func or(_ other: Self) -> Self {
        self == .unset ? other : self
    }
}

extension MuterConfiguration {
    /// The values `suspectTestFilePercent` and its flag take: a share of files, from 1 to 100.
    static let filePercents = 1 ... 100
    /// The values `suspectTestMinimumFiles` and its flag take: a count of files, at least 1.
    static let minimumFiles = 1 ... Int.max
    /// The values `keepLogFolders` and its flag take: at least 2, so the run before this one is always kept.
    static let logFolderCounts = 2 ... Int.max
    /// The values `controlRunEvery`, `suspectKillReruns`, `propertySurvivorReruns`, `propertySurvivorRerunLimit` and
    /// their flags take: 0 for none.
    static let counts = 0 ... Int.max
    /// The values `coverageThreshold` and its flag take: a percentage.
    static let coveragePercents: ClosedRange<Double> = 0 ... 100

    /// How a refusal gives `range`: "at least 2", or "from 1 to 100".
    static func bounds(of range: ClosedRange<Int>) -> String {
        range.upperBound == Int.max
            ? "at least \(range.lowerBound)" : "from \(range.lowerBound) to \(range.upperBound)"
    }

    /// This configuration with `flags` in: `--exclude-calls`' entries after `excludeCalls`', and each other value
    /// given in place of its key's.
    func withKeyFlags(_ flags: KeyFlags) -> Self {
        var copy = self
        copy.excludeCallList += flags.excludeCalls
        copy.coverageThreshold = flags.coverageThreshold ?? coverageThreshold
        copy.explicitBuildSystem = flags.buildSystem ?? explicitBuildSystem
        copy.stopAtFirstFailure = flags.stopAtFirstFailure.or(stopAtFirstFailure)
        copy.workersShareBuild = flags.workersShareBuild.or(workersShareBuild)
        copy.oneWorkerSimulator = flags.oneWorkerSimulator.or(oneWorkerSimulator)
        copy.suspectTestFilePercent = flags.suspectTestFilePercent ?? suspectTestFilePercent
        copy.suspectTestMinimumFiles = flags.suspectTestMinimumFiles ?? suspectTestMinimumFiles
        copy.controlRunEvery = flags.controlRunEvery ?? controlRunEvery
        copy.suspectKillReruns = flags.suspectKillReruns ?? suspectKillReruns
        copy.keepAllLogs = flags.keepAllLogs.or(keepAllLogs)
        copy.keepLogFolders = flags.keepLogFolders ?? keepLogFolders
        copy.keepSwiftLintPhases = flags.keepSwiftLintPhases.or(keepSwiftLintPhases)
        copy.propertyTestFilter = flags.propertyTestFilter ?? propertyTestFilter
        copy.propertySurvivorReruns = flags.propertySurvivorReruns ?? propertySurvivorReruns
        copy.propertySurvivorRerunLimit = flags.propertySurvivorRerunLimit ?? propertySurvivorRerunLimit
        return copy
    }
}
