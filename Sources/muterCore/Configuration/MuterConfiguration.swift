import Foundation
import Yams

struct MuterConfiguration: Equatable, Codable {
    let testCommandArguments: [String]
    // A `var` only so `withExecutable` can copy `self` and change just this field. Rebuilding with
    // `init` instead silently resets any field the call leaves out, as every parameter has a default.
    var testCommandExecutable: String
    /// File exclusion list (`exclude:`), with `--exclude`'s entries after the file's. An entry that starts with `!`
    /// keeps what it matches (`SourceFileExcludes`). A `var` only so `overriding` can copy `self` and add to it.
    var excludeFileList: [String]
    /// Exclusion list of functions for Remove Side Effects.
    let excludeCallList: [String]
    /// A percentage from 0 to 100 (`coverageThreshold:`), the same for every build system: a file whose share of lines
    /// the tests ran with coverage on is at or below it is left out. 0, the default, leaves out the files no test
    /// runs. A file with no lines to run is never left out.
    let coverageThreshold: Double
    // A `var` only so `withDefaultTestSuiteTimeout` can copy `self` and change just this field.
    // Rebuilding with `init` instead silently resets any field the call leaves out, as every parameter
    // has a default.
    var testSuiteTimeout: Double?
    /// Seconds before each step ahead of the first mutant that builds the project or runs its tests is stopped
    /// (`buildTimeout:`): the coverage run, each xcodebuild build for testing, each baseline run, a worker clone's
    /// baseline and an xcodebuild worker's run with no mutant on. The direct and timed test runs, which follow the
    /// baseline and don't build, get a shorter limit, from the baseline's time, never above this
    /// (`followingRunLimit`). nil, the default, sets no limit. A `var` only so `overriding` can copy `self` and change
    /// just this field.
    var buildTimeout: Double?
    /// How many mutants to test at once (`mutationTestWorkers:`). A SwiftPM worker runs the test command in its own
    /// clone of the mutated project, because `swift test` locks the package's build directory. Each clone is built
    /// once before testing, so the paths compiled into its tests point into it. An xcodebuild worker tests on a
    /// simulator of its own, from the mutated project's one build (see `XcodeWorker`). Other projects, and xcodebuild
    /// projects that test elsewhere, test one at a time (`parallelWorkersUnsupportedReason`); so does 1, though one
    /// xcodebuild worker may still test on a simulator of its own (`oneWorkerSimulator`). nil leaves it to
    /// `workerCount(testing:)`: several on a SwiftPM project, and otherwise one. A `var` only so `overriding` can copy
    /// `self` and change just this field.
    var mutationTestWorkers: Int?
    /// Whether a SwiftPM run's workers may share the mutated project's build rather than each have a clone
    /// (`workersShareBuild:`): `unset` and `enabled` when a direct run of the tests with no mutant on wrote nothing in
    /// the project, `disabled` never.
    let workersShareBuild: ConfigurationSwitch
    /// Optional explicit build system from the `buildSystem:` config key. When set it overrides the
    /// executable-basename heuristic — needed when `executable` is a wrapper script (e.g. one that
    /// restores env / forwards SIMCTL_CHILD_ vars) whose filename isn't literally `xcodebuild`/`swift`.
    let explicitBuildSystem: BuildSystem?
    /// Whether a mutant's test run stops at its first failed test (`stopAtFirstFailure:`), which already
    /// decides that the mutant is killed. `unset` leaves it to the default; see `stopsAtFirstFailure`. A `var` only so
    /// `withoutStoppingAtFirstFailure` can copy `self` and change just this field.
    var stopAtFirstFailure: ConfigurationSwitch
    /// Whether one xcodebuild worker tests on a simulator SwiftMutator makes, rather than on the test command's
    /// destination (`oneWorkerSimulator:`): `unset` decides from the project and the baseline
    /// (`SimulatorWorkerSetup.oneWorkerPlan(for:state:)`), `enabled` whenever the destination is a simulator and there
    /// are 2 or more mutants to test, `disabled` never. Several workers test on simulators of their own whatever it
    /// says.
    let oneWorkerSimulator: ConfigurationSwitch
    /// When a test is suspect (`suspectTestFilePercent:`, from 1 to 100, and `suspectTestMinimumFiles:`, at least 1):
    /// nil leaves each to `SuspectTestThresholds.standard`. They change no result already recorded, only what the
    /// reports say and which kills a later session tests again alone, so a resume lets them change
    /// (`ResumeCheck.keysThatDontAffectOutcomes`), as it does `failUnder`.
    let suspectTestFilePercent: Int?
    let suspectTestMinimumFiles: Int?
    /// How many mutants to test for each control run, a run with no mutant on among theirs (`controlRunEvery:`, a
    /// whole number, 0 for none): nil leaves it to `defaultMutantsPerControlRun`. A control run changes no mutant's
    /// result, only which tests are suspect, so which kills are tested again alone, so a resume lets it change.
    let controlRunEvery: Int?
    /// How many kills a run tests again alone for only suspect tests failing for them (`suspectKillReruns:`, a whole
    /// number, 0 for none): nil leaves it to `defaultSuspectKillReruns`. It changes no result already recorded, so a
    /// resume lets it change.
    let suspectKillReruns: Int?
    /// Whether every mutant's test run keeps its log (`keepAllLogs:`): `unset` and `disabled` keep a mutant's log only
    /// when its results line can't stand in for it, `enabled` keeps every log. See `MutationTestLog.isKept`. Which logs
    /// are kept changes no result, so a resume lets it change.
    let keepAllLogs: ConfigurationSwitch
    /// How many runs' log folders to keep in `<project>_muter_logs` (`keepLogFolders:`, a whole number, at least 2),
    /// this run's included, so the run before it is always kept; nil, the default, removes none. A run's folders are
    /// those of each of its sessions, and only a run with a results file counts. See `LogFolderPruning`. Which folders
    /// are kept changes no result, so a resume lets it change.
    let keepLogFolders: Int?
    /// Whether the build phases of the copy's Xcode projects keep running SwiftLint (`keepSwiftLintPhases:`): `unset`
    /// and `disabled` turn it off in the copy, never in the project, `enabled` keeps it (`TurnOffSwiftLintPhases`).
    /// Each mutated file turns every rule off, so a phase only costs time on each build of the copy. It changes no
    /// result, so a resume lets it change.
    let keepSwiftLintPhases: ConfigurationSwitch
    /// The percent, from 0 to 100, up to 6 decimals, below which a finished run's headline score fails it with status 2
    /// (`failUnder:`, `ScoreGate`); nil, the default, checks none. It changes no result, so a resume lets it change.
    /// A `var` only so `overriding` can copy `self` and change just this field.
    var failUnder: Double?
    /// The globs that pick out property tests (`propertyTests:`, `PropertyTestPattern`), which the reports split each
    /// kill by (`PropertyKillSummary`); nil, the default, splits none. They change only what the reports say, never a
    /// mutant's result, so a resume lets them change. A `var` only so `overriding` can copy `self` and change just this
    /// field.
    var propertyTests: [String]?
    /// The operators a run mutates with (`operators:`, at least one); nil, the default, means all of them.
    /// `--operators` wins over this key and over `skipOperators`. See `Run.Options.chosenOperators(given:)`.
    let operators: [MutationOperator.Id]?
    /// The operators a run leaves out (`skipOperators:`), of `operators` or of all of them; `--skip-operators` is taken
    /// in its place. nil and an empty list leave none out.
    let skipOperators: [MutationOperator.Id]?
    /// The reports a run saves besides `-f`'s, each in its own format (`reports:`, as `format:path`), with each path as
    /// written: a relative one is resolved against the project's folder, where the run starts, when it is used
    /// (`reportRequests(in:)`). nil, the default, saves none. `--report` is taken in its place. Never `report`'s: it
    /// would replace the run's own files. They change no result, so a resume lets them change. A `var` only so
    /// `overriding` can copy `self` and change just this field.
    var reports: [ReportRequest]?
    /// What selects the property tests alone, for the runs that test a killed mutant again with only them
    /// (`propertyTestFilter:`, `PropertyReruns`): each entry is given to `swift test` as `--filter <entry>`, and to
    /// xcodebuild as `-only-testing:<entry>`. nil, the default, runs none. A kill whose recorded tests include no
    /// property test is tested again, so the reports can tell "only by examples" from "by both" where a run stopped at
    /// its first failed test. It changes no mutant's result, so a resume lets it change.
    let propertyTestFilter: [String]?
    /// How many times each survivor whose code ran is tested again with only the property tests `propertyTestFilter`
    /// selects, stopping at the first run that doesn't pass (`propertySurvivorReruns:`, a whole number, 0 for none);
    /// nil, the default, tests none again (`PropertySurvivorReruns`). A property test tries a sample of inputs, so a
    /// survivor may only have missed the one that tells it apart: a later run's failure says the law holds the change
    /// and the generator rarely reaches it. It changes no mutant's result, so a resume lets it change.
    let propertySurvivorReruns: Int?
    /// How many survivors a run tests again with the property tests (`propertySurvivorRerunLimit:`, a whole number, 0
    /// for none), over however many sessions it takes: nil leaves it to `defaultPropertySurvivorRerunLimit`. It
    /// changes no result, so a resume lets it change.
    let propertySurvivorRerunLimit: Int?
    /// Whether a line `FailedTestLine` matches shows a failed test. Not a configuration key: false once a
    /// passing baseline has printed such a line, or one `CrashLine` matches, as its tests print text shaped like a
    /// failure. Such a line then neither stops a mutant's run nor counts a timed-out run killed. A `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    var failedTestLinesAreReliable = true
    /// Whether a mutant's run goes on past its first failed test, whatever `stopsAtFirstFailure` says, so that its log
    /// shows every test that fails. Not a configuration key, and apart from `stopAtFirstFailure`, as these runs keep
    /// the environment and the unbuffered output of the session's others. A `var` only so `goingToEachRunsEnd` can
    /// copy `self` and change just this field.
    var runsGoToTheirEnd = false
    /// The tests that a passing baseline's lines showed failing, which a mutant's list of failed tests leaves out, as
    /// those lines are the tests' own text, printed whatever the mutant. Not a configuration key; a `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    var failedTestLookalikes: Set<FailedTestLine.TestIdentity> = []
    /// How a mutant's run starts the test bundles without `swift test`. Not a configuration key: set once a run of
    /// them with no mutant on has matched the baseline (see `DirectTestRun`). A `var` only so `withDirectTestRun` can
    /// copy `self` and change just this field.
    var directTestRun: DirectTestRun?
    /// Where an xcodebuild mutant's run tests from, and what it writes to. Not a configuration key: set for each
    /// worker once the baseline has passed (see `XcodeWorker`). A `var` only so `forXcodeWorker` can copy `self` and
    /// change just this field.
    var xcodeWorker: XcodeWorker?
    /// What a run's test command adds to select some of the tests: `--filter` or `-only-testing:` for each of
    /// `propertyTestFilter`'s entries (`withPropertyTestFilter`). Not a configuration key; a `var` only so that can
    /// copy `self` and change just this field.
    var testFilterArguments: [String] = []
    /// Whether the run found no configuration file, and uses what `init` would write there
    /// (`MuterConfiguration.generated(from:in:)`). Not a configuration key: the results header records it
    /// (`ResultsHeader.configurationWorkedOut`), so a resume can say how the configuration came to differ. A `var` only
    /// so `workedOutFromTheProject` can copy `self` and change just this field.
    var workedOut = false

    var buildSystem: BuildSystem {
        if let explicitBuildSystem, explicitBuildSystem != .unknown {
            return explicitBuildSystem
        }

        guard let executableName = testCommandExecutable.components(separatedBy: "/").last?.trimmed else {
            return .unknown
        }

        return BuildSystem(rawValue: executableName)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case testCommandArguments = "arguments"
        case testCommandExecutable = "executable"
        case excludeFileList = "exclude"
        case excludeCallList = "excludeCalls"
        case coverageThreshold
        case testSuiteTimeout = "mutationTestTimeout"
        case buildTimeout
        case explicitBuildSystem = "buildSystem"
        case mutationTestWorkers
        case workersShareBuild
        case stopAtFirstFailure
        case oneWorkerSimulator
        case suspectTestFilePercent
        case suspectTestMinimumFiles
        case controlRunEvery
        case suspectKillReruns
        case keepAllLogs
        case keepLogFolders
        case keepSwiftLintPhases
        case failUnder
        case propertyTests
        case propertyTestFilter
        case propertySurvivorReruns
        case propertySurvivorRerunLimit
        case operators
        case skipOperators
        case reports
    }

    init(
        executable: String = "",
        arguments: [String] = [],
        excludeList: [String] = [],
        excludeCallList callList: [String] = [],
        coverageThreshold threshold: Double = 0,
        testSuiteTimeOut timeout: Double? = nil,
        buildSystem: BuildSystem? = nil,
        mutationTestWorkers workers: Int? = nil,
        workersShareBuild: ConfigurationSwitch = .unset,
        stopAtFirstFailure: ConfigurationSwitch = .unset,
        buildTimeout: Double? = nil,
        oneWorkerSimulator: ConfigurationSwitch = .unset,
        suspectTestFilePercent: Int? = nil,
        suspectTestMinimumFiles: Int? = nil,
        controlRunEvery: Int? = nil,
        suspectKillReruns: Int? = nil,
        keepAllLogs: ConfigurationSwitch = .unset,
        keepLogFolders: Int? = nil,
        keepSwiftLintPhases: ConfigurationSwitch = .unset,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        propertyTestFilter: [String]? = nil,
        propertySurvivorReruns: Int? = nil,
        propertySurvivorRerunLimit: Int? = nil,
        operators: [MutationOperator.Id]? = nil,
        skipOperators: [MutationOperator.Id]? = nil,
        reports: [ReportRequest]? = nil
    ) {
        testCommandExecutable = executable
        testCommandArguments = arguments
        excludeFileList = excludeList
        excludeCallList = callList
        coverageThreshold = threshold
        testSuiteTimeout = timeout
        explicitBuildSystem = buildSystem
        mutationTestWorkers = workers
        self.workersShareBuild = workersShareBuild
        self.stopAtFirstFailure = stopAtFirstFailure
        self.buildTimeout = buildTimeout
        self.oneWorkerSimulator = oneWorkerSimulator
        self.suspectTestFilePercent = suspectTestFilePercent
        self.suspectTestMinimumFiles = suspectTestMinimumFiles
        self.controlRunEvery = controlRunEvery
        self.suspectKillReruns = suspectKillReruns
        self.keepAllLogs = keepAllLogs
        self.keepLogFolders = keepLogFolders
        self.keepSwiftLintPhases = keepSwiftLintPhases
        self.failUnder = failUnder
        self.propertyTests = propertyTests
        self.propertyTestFilter = propertyTestFilter
        self.propertySurvivorReruns = propertySurvivorReruns
        self.propertySurvivorRerunLimit = propertySurvivorRerunLimit
        self.operators = operators
        self.skipOperators = skipOperators
        self.reports = reports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        testCommandExecutable = try container.decode(String.self, forKey: .testCommandExecutable)
        testCommandArguments = try container.decode([String].self, forKey: .testCommandArguments)

        // Each throws on a value of another type, so `exclude: Sources/Generated`, one string, is a configuration error
        // rather than nothing excluded. A blank key is an empty list, or 0.
        excludeFileList = try Self.list(forKey: .excludeFileList, of: "paths or globs", in: container)
        excludeCallList = try Self.list(forKey: .excludeCallList, of: "function names", in: container)
        coverageThreshold = try Self.number(forKey: .coverageThreshold, in: container) ?? 0
        testSuiteTimeout = try Self.number(forKey: .testSuiteTimeout, in: container)
        buildTimeout = try Self.number(forKey: .buildTimeout, in: container)
        explicitBuildSystem = try Self.buildSystem(forKey: .explicitBuildSystem, in: container)
        mutationTestWorkers = try container.decodeIfPresent(Int.self, forKey: .mutationTestWorkers)
        workersShareBuild = try container.decode(ConfigurationSwitch.self, forKey: .workersShareBuild)
        // Throws on a value that isn't a Boolean, so a typo is a configuration error rather than "unset".
        stopAtFirstFailure = try container.decode(ConfigurationSwitch.self, forKey: .stopAtFirstFailure)
        oneWorkerSimulator = try container.decode(ConfigurationSwitch.self, forKey: .oneWorkerSimulator)
        suspectTestFilePercent = try Self.whole(forKey: .suspectTestFilePercent, in: 1 ... 100, in: container)
        suspectTestMinimumFiles = try Self.whole(forKey: .suspectTestMinimumFiles, in: 1 ... Int.max, in: container)
        controlRunEvery = try Self.whole(forKey: .controlRunEvery, in: 0 ... Int.max, in: container)
        suspectKillReruns = try Self.whole(forKey: .suspectKillReruns, in: 0 ... Int.max, in: container)
        keepAllLogs = try container.decode(ConfigurationSwitch.self, forKey: .keepAllLogs)
        keepLogFolders = try Self.whole(forKey: .keepLogFolders, in: 2 ... Int.max, in: container)
        keepSwiftLintPhases = try container.decode(ConfigurationSwitch.self, forKey: .keepSwiftLintPhases)
        failUnder = try Self.percent(forKey: .failUnder, in: container)
        propertyTests = try Self.globs(forKey: .propertyTests, in: container)
        propertyTestFilter = try Self.globs(forKey: .propertyTestFilter, in: container)
        propertySurvivorReruns = try Self.whole(forKey: .propertySurvivorReruns, in: 0 ... Int.max, in: container)
        propertySurvivorRerunLimit = try Self.whole(
            forKey: .propertySurvivorRerunLimit, in: 0 ... Int.max, in: container
        )
        operators = try Self.operators(forKey: .operators, in: container)
        // A blank `operators:` is an empty list, not an unset key, which would use every operator.
        let isBlank = container.contains(.operators) ? try container.decodeNil(forKey: .operators) : false
        if isBlank || operators?.isEmpty == true {
            throw DecodingError.dataCorruptedError(
                forKey: .operators,
                in: container,
                debugDescription: "operators must name at least one operator. Leave it out to use them all."
            )
        }
        skipOperators = try Self.operators(forKey: .skipOperators, in: container)
        reports = try Self.reports(forKey: .reports, in: container)
    }

    /// Writes each configuration key as `init(from:)` reads it, in the order of `CodingKeys`, leaving out those not
    /// set. `failUnder` is written in YAML as plain decimal digits (`WrittenPercent`), which `init(from:)` reads back,
    /// rather than as Yams writes a number, 8e+1.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(testCommandArguments, forKey: .testCommandArguments)
        try container.encode(testCommandExecutable, forKey: .testCommandExecutable)
        try container.encode(excludeFileList, forKey: .excludeFileList)
        try container.encode(excludeCallList, forKey: .excludeCallList)
        try container.encode(coverageThreshold, forKey: .coverageThreshold)
        try container.encodeIfPresent(testSuiteTimeout, forKey: .testSuiteTimeout)
        try container.encodeIfPresent(buildTimeout, forKey: .buildTimeout)
        try container.encodeIfPresent(explicitBuildSystem, forKey: .explicitBuildSystem)
        try container.encodeIfPresent(mutationTestWorkers, forKey: .mutationTestWorkers)
        try container.encode(workersShareBuild, forKey: .workersShareBuild)
        try container.encode(stopAtFirstFailure, forKey: .stopAtFirstFailure)
        try container.encode(oneWorkerSimulator, forKey: .oneWorkerSimulator)
        try container.encodeIfPresent(suspectTestFilePercent, forKey: .suspectTestFilePercent)
        try container.encodeIfPresent(suspectTestMinimumFiles, forKey: .suspectTestMinimumFiles)
        try container.encodeIfPresent(controlRunEvery, forKey: .controlRunEvery)
        try container.encodeIfPresent(suspectKillReruns, forKey: .suspectKillReruns)
        try container.encode(keepAllLogs, forKey: .keepAllLogs)
        try container.encodeIfPresent(keepLogFolders, forKey: .keepLogFolders)
        try container.encode(keepSwiftLintPhases, forKey: .keepSwiftLintPhases)
        try container.encodeIfPresent(failUnder.map(WrittenPercent.init), forKey: .failUnder)
        try container.encodeIfPresent(propertyTests, forKey: .propertyTests)
        try container.encodeIfPresent(propertyTestFilter, forKey: .propertyTestFilter)
        try container.encodeIfPresent(propertySurvivorReruns, forKey: .propertySurvivorReruns)
        try container.encodeIfPresent(propertySurvivorRerunLimit, forKey: .propertySurvivorRerunLimit)
        try container.encodeIfPresent(operators, forKey: .operators)
        try container.encodeIfPresent(skipOperators, forKey: .skipOperators)
        try container.encodeIfPresent(reports, forKey: .reports)
    }

    init(from data: Data) throws {
        do {
            self = try YAMLDecoder().decode(Self.self, from: data)
        } catch {
            let yamlError = error
            do {
                self = try JSONDecoder().decode(Self.self, from: data)
            } catch {
                // YAML's reason, which names the key at fault, rather than that the file isn't JSON.
                throw yamlError
            }
        }
    }

    static let fileName = "muter.conf"
    static let `extension` = "yml"
    static let fileNameWithExtension = "\(fileName).\(`extension`)"
    static let legacyFileNameWithExtension = "\(fileName).json"

    var asData: Data {
        get throws {
            Data(try YAMLEncoder().encode(self).utf8)
        }
    }
}
