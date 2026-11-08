import Foundation
import Yams

struct MuterConfiguration: Equatable, Codable {
    let testCommandArguments: [String]
    // A `var` only so `withExecutable` can copy `self` and change just this field. Rebuilding with
    // `init` instead silently resets any field the call leaves out, as every parameter has a default.
    private(set) var testCommandExecutable: String
    /// File exclusion list (`exclude:`), with `--exclude`'s entries after the file's. An entry that starts with `!`
    /// keeps what it matches (`SourceFileExcludes`). A `var` only so `overriding` can copy `self` and add to it.
    private(set) var excludeFileList: [String]
    /// Exclusion list of functions for Remove Side Effects.
    let excludeCallList: [String]
    /// A percentage from 0 to 100 (`coverageThreshold:`), the same for every build system: a file whose share of lines
    /// the tests ran with coverage on is at or below it is left out. 0, the default, leaves out the files no test
    /// runs. A file with no lines to run is never left out.
    let coverageThreshold: Double
    // A `var` only so `withDefaultTestSuiteTimeout` can copy `self` and change just this field.
    // Rebuilding with `init` instead silently resets any field the call leaves out, as every parameter
    // has a default.
    private(set) var testSuiteTimeout: Double?
    /// Seconds before each step ahead of the first mutant that builds the project or runs its tests is stopped
    /// (`buildTimeout:`): the coverage run, each xcodebuild build for testing, each baseline run, a worker clone's
    /// baseline and an xcodebuild worker's run with no mutant on. The direct and timed test runs, which follow the
    /// baseline and don't build, get a shorter limit, from the baseline's time, never above this
    /// (`followingRunLimit`). nil, the default, sets no limit. A `var` only so `overriding` can copy `self` and change
    /// just this field.
    private(set) var buildTimeout: Double?
    /// How many mutants to test at once (`mutationTestWorkers:`). A SwiftPM worker runs the test command in its own
    /// clone of the mutated project, because `swift test` locks the package's build directory. Each clone is built
    /// once before testing, so the paths compiled into its tests point into it. An xcodebuild worker tests on a
    /// simulator of its own, from the mutated project's one build (see `XcodeWorker`). Other projects, and xcodebuild
    /// projects that test elsewhere, test one at a time (`parallelWorkersUnsupportedReason`); so does 1, though one
    /// xcodebuild worker may still test on a simulator of its own (`oneWorkerSimulator`). nil leaves it to
    /// `workerCount(testing:)`: several on a SwiftPM project, and otherwise one. A `var` only so `overriding` can copy
    /// `self` and change just this field.
    private(set) var mutationTestWorkers: Int?
    /// Whether a SwiftPM run's workers may share the mutated project's build rather than each have a clone
    /// (`workersShareBuild:`): nil and true when a direct run of the tests with no mutant on wrote nothing in the
    /// project, false never.
    let workersShareBuild: Bool?
    /// Optional explicit build system from the `buildSystem:` config key. When set it overrides the
    /// executable-basename heuristic — needed when `executable` is a wrapper script (e.g. one that
    /// restores env / forwards SIMCTL_CHILD_ vars) whose filename isn't literally `xcodebuild`/`swift`.
    let explicitBuildSystem: BuildSystem?
    /// Whether a mutant's test run stops at its first failed test (`stopAtFirstFailure:`), which already
    /// decides that the mutant is killed. nil leaves it to the default; see `stopsAtFirstFailure`. A `var` only so
    /// `withoutStoppingAtFirstFailure` can copy `self` and change just this field.
    private(set) var stopAtFirstFailure: Bool?
    /// Whether one xcodebuild worker tests on a simulator SwiftMutator makes, rather than on the test command's
    /// destination (`oneWorkerSimulator:`): nil decides from the project and the baseline
    /// (`SimulatorWorkerSetup.oneWorkerPlan(for:state:)`), true whenever the destination is a simulator and there are 2
    /// or more mutants to test, false never. Several workers test on simulators of their own whatever it says.
    let oneWorkerSimulator: Bool?
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
    /// Whether every mutant's test run keeps its log (`keepAllLogs:`): nil and false keep a mutant's log only when its
    /// results line can't stand in for it, true keeps every log. See `MutationTestLog.isKept`. Which logs are kept
    /// changes no result, so a resume lets it change.
    let keepAllLogs: Bool?
    /// How many runs' log folders to keep in `<project>_muter_logs` (`keepLogFolders:`, a whole number, at least 2),
    /// this run's included, so the run before it is always kept; nil, the default, removes none. A run's folders are
    /// those of each of its sessions, and only a run with a results file counts. See `LogFolderPruning`. Which folders
    /// are kept changes no result, so a resume lets it change.
    let keepLogFolders: Int?
    /// The percent, from 0 to 100, up to 6 decimals, below which a finished run's headline score fails it with status 2
    /// (`failUnder:`, `ScoreGate`); nil, the default, checks none. It changes no result, so a resume lets it change.
    /// A `var` only so `overriding` can copy `self` and change just this field.
    private(set) var failUnder: Double?
    /// The globs that pick out property tests (`propertyTests:`, `PropertyTestPattern`), which the reports split each
    /// kill by (`PropertyKillSummary`); nil, the default, splits none. They change only what the reports say, never a
    /// mutant's result, so a resume lets them change. A `var` only so `overriding` can copy `self` and change just this
    /// field.
    private(set) var propertyTests: [String]?
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
    private(set) var reports: [ReportRequest]?
    /// What selects the property tests alone, for the runs that test a killed mutant again with only them
    /// (`propertyTestFilter:`, `PropertyReruns`): each entry is given to `swift test` as `--filter <entry>`, and to
    /// xcodebuild as `-only-testing:<entry>`. nil, the default, runs none. A kill whose recorded tests include no
    /// property test is tested again, so the reports can tell "only by examples" from "by both" where a run stopped at
    /// its first failed test. It changes no mutant's result, so a resume lets it change.
    let propertyTestFilter: [String]?
    /// Whether a line `FailedTestLine` matches shows a failed test. Not a configuration key: false once a
    /// passing baseline has printed such a line, or one `CrashLine` matches, as its tests print text shaped like a
    /// failure. Such a line then neither stops a mutant's run nor counts a timed-out run killed. A `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    private(set) var failedTestLinesAreReliable = true
    /// Whether a mutant's run goes on past its first failed test, whatever `stopsAtFirstFailure` says, so that its log
    /// shows every test that fails. Not a configuration key, and apart from `stopAtFirstFailure`, as these runs keep
    /// the environment and the unbuffered output of the session's others. A `var` only so `goingToEachRunsEnd` can
    /// copy `self` and change just this field.
    private(set) var runsGoToTheirEnd = false
    /// The tests that a passing baseline's lines showed failing, which a mutant's list of failed tests leaves out, as
    /// those lines are the tests' own text, printed whatever the mutant. Not a configuration key; a `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    private(set) var failedTestLookalikes: Set<FailedTestLine.TestIdentity> = []
    /// How a mutant's run starts the test bundles without `swift test`. Not a configuration key: set once a run of
    /// them with no mutant on has matched the baseline (see `DirectTestRun`). A `var` only so `withDirectTestRun` can
    /// copy `self` and change just this field.
    private(set) var directTestRun: DirectTestRun?
    /// Where an xcodebuild mutant's run tests from, and what it writes to. Not a configuration key: set for each
    /// worker once the baseline has passed (see `XcodeWorker`). A `var` only so `forXcodeWorker` can copy `self` and
    /// change just this field.
    private(set) var xcodeWorker: XcodeWorker?
    /// What a run's test command adds to select some of the tests: `--filter` or `-only-testing:` for each of
    /// `propertyTestFilter`'s entries (`withPropertyTestFilter`). Not a configuration key; a `var` only so that can
    /// copy `self` and change just this field.
    private(set) var testFilterArguments: [String] = []

    var buildSystem: BuildSystem {
        if let explicitBuildSystem, explicitBuildSystem != .unknown {
            return explicitBuildSystem
        }

        guard let buildSystem = testCommandExecutable.components(separatedBy: "/").last?.trimmed else {
            return .unknown
        }

        return BuildSystem(rawValue: buildSystem)
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
        case failUnder
        case propertyTests
        case propertyTestFilter
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
        workersShareBuild: Bool? = nil,
        stopAtFirstFailure: Bool? = nil,
        buildTimeout: Double? = nil,
        oneWorkerSimulator: Bool? = nil,
        suspectTestFilePercent: Int? = nil,
        suspectTestMinimumFiles: Int? = nil,
        controlRunEvery: Int? = nil,
        suspectKillReruns: Int? = nil,
        keepAllLogs: Bool? = nil,
        keepLogFolders: Int? = nil,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        propertyTestFilter: [String]? = nil,
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
        self.failUnder = failUnder
        self.propertyTests = propertyTests
        self.propertyTestFilter = propertyTestFilter
        self.operators = operators
        self.skipOperators = skipOperators
        self.reports = reports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        testCommandExecutable = try container.decode(String.self, forKey: .testCommandExecutable)
        testCommandArguments = try container.decode([String].self, forKey: .testCommandArguments)

        excludeFileList = container.decode([String].self, default: [], forKey: .excludeFileList)
        excludeCallList = container.decode([String].self, default: [], forKey: .excludeCallList)
        coverageThreshold = container.decode(Double.self, default: 0, forKey: .coverageThreshold)
        testSuiteTimeout = try Self.seconds(forKey: .testSuiteTimeout, in: container)
        buildTimeout = try Self.seconds(forKey: .buildTimeout, in: container)
        explicitBuildSystem = (try container.decodeIfPresent(String.self, forKey: .explicitBuildSystem))
            .map(BuildSystem.init(rawValue:))
        mutationTestWorkers = try container.decodeIfPresent(Int.self, forKey: .mutationTestWorkers)
        workersShareBuild = try container.decodeIfPresent(Bool.self, forKey: .workersShareBuild)
        // Throws on a value that isn't a Boolean, so a typo is a configuration error rather than "unset".
        stopAtFirstFailure = try container.decodeIfPresent(Bool.self, forKey: .stopAtFirstFailure)
        oneWorkerSimulator = try container.decodeIfPresent(Bool.self, forKey: .oneWorkerSimulator)
        suspectTestFilePercent = try Self.whole(forKey: .suspectTestFilePercent, in: 1 ... 100, in: container)
        suspectTestMinimumFiles = try Self.whole(forKey: .suspectTestMinimumFiles, in: 1 ... Int.max, in: container)
        controlRunEvery = try Self.whole(forKey: .controlRunEvery, in: 0 ... Int.max, in: container)
        suspectKillReruns = try Self.whole(forKey: .suspectKillReruns, in: 0 ... Int.max, in: container)
        keepAllLogs = try container.decodeIfPresent(Bool.self, forKey: .keepAllLogs)
        keepLogFolders = try Self.whole(forKey: .keepLogFolders, in: 2 ... Int.max, in: container)
        failUnder = try Self.percent(forKey: .failUnder, in: container)
        propertyTests = try Self.globs(forKey: .propertyTests, in: container)
        propertyTestFilter = try Self.globs(forKey: .propertyTestFilter, in: container)
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

    /// The reports `key` asks for, each `format:path` (`ReportRequest.parse`), or nil if it isn't set. Throws on an
    /// entry that isn't one, as `--report` refuses it, and on a value that isn't a list of strings, so a typo is a
    /// configuration error rather than a report not saved.
    private static func reports(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [ReportRequest]? {
        try container.decodeIfPresent([String].self, forKey: key)?.map { entry in
            switch ReportRequest.parse(entry) {
            case let .success(request):
                return request
            case let .failure(problem):
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue): \(problem), not \(entry)"
                )
            }
        }
    }

    /// `reports`, with each relative path resolved against `folder`, the project's: what a run saves; none without the
    /// key.
    func reportRequests(in folder: URL) -> [ReportRequest] {
        (reports ?? []).map { $0.resolved(in: folder.path) }
    }

    /// The operators `key` names, or nil if it isn't set. Throws on a name that isn't an operator, and on a value that
    /// isn't a list of strings, so a typo is a configuration error rather than an operator left in or out.
    private static func operators(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [MutationOperator.Id]? {
        try container.decodeIfPresent([String].self, forKey: key)?.map { name in
            guard let found = MutationOperator.Id(rawValue: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue): \(name) isn't an operator. "
                        + "The operators are: \(MutationOperator.Id.description)"
                )
            }
            return found
        }
    }

    /// A list of globs, or of test filters, or nil if `key` isn't set. Throws on an empty entry, which would select
    /// nothing, and on a value that isn't a list of strings, so a typo is a configuration error rather than "unset".
    private static func globs(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String]? {
        guard let globs = try container.decodeIfPresent([String].self, forKey: key) else { return nil }
        if let error = PropertyTestPattern.problem(with: globs) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue): \(error)"
            )
        }
        return globs
    }

    /// A percent from 0 to 100, or nil if `key` isn't set, written as `--fail-under` takes it (`ScoreGate.percent`):
    /// plain decimal digits, with at most `ScoreGate.maximumDecimals` decimals, so not 1e2, 0x50, 8_0 or 1:20, which
    /// YAML would read as numbers. A JSON configuration, such as a results file's header, holds a number instead,
    /// whose shortest decimal form is checked the same way. Throws on any other value, so a typo is a configuration
    /// error rather than "unset".
    private static func percent(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        // YAML gives any scalar as the text it is written with; JSON gives only a string so.
        let text: String
        let number: Double?
        if let written = try? container.decodeIfPresent(String.self, forKey: key) {
            (text, number) = (written, nil)
        } else if let value = try seconds(forKey: key, in: container) {
            (text, number) = (ScoreGate.shown(value), value)
        } else {
            return nil
        }
        // A number must be the one its text gives, so one with more decimals than its text shows is refused.
        guard let percent = ScoreGate.percent(text), number.map({ $0 == percent }) ?? true else {
            let shown = number.map { Double(text) == $0 ? text : "\($0)" } ?? text
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a number from 0 to 100, with at most "
                    + "\(ScoreGate.maximumDecimals) decimals, such as 80 or 72.5, not \(shown)"
            )
        }
        return percent
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
        try container.encodeIfPresent(workersShareBuild, forKey: .workersShareBuild)
        try container.encodeIfPresent(stopAtFirstFailure, forKey: .stopAtFirstFailure)
        try container.encodeIfPresent(oneWorkerSimulator, forKey: .oneWorkerSimulator)
        try container.encodeIfPresent(suspectTestFilePercent, forKey: .suspectTestFilePercent)
        try container.encodeIfPresent(suspectTestMinimumFiles, forKey: .suspectTestMinimumFiles)
        try container.encodeIfPresent(controlRunEvery, forKey: .controlRunEvery)
        try container.encodeIfPresent(suspectKillReruns, forKey: .suspectKillReruns)
        try container.encodeIfPresent(keepAllLogs, forKey: .keepAllLogs)
        try container.encodeIfPresent(keepLogFolders, forKey: .keepLogFolders)
        try container.encodeIfPresent(failUnder.map(WrittenPercent.init), forKey: .failUnder)
        try container.encodeIfPresent(propertyTests, forKey: .propertyTests)
        try container.encodeIfPresent(propertyTestFilter, forKey: .propertyTestFilter)
        try container.encodeIfPresent(operators, forKey: .operators)
        try container.encodeIfPresent(skipOperators, forKey: .skipOperators)
        try container.encodeIfPresent(reports, forKey: .reports)
    }

    /// A percent, written in JSON as a number and in YAML as a plain scalar, both in decimal digits
    /// (`ScoreGate.shown`): 80, 72.5, 0.00001.
    private struct WrittenPercent: YAMLEncodable {
        let value: Double

        /// A `Decimal`, which JSONEncoder writes in plain digits, as 0.00001 rather than 1e-05.
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Decimal(string: ScoreGate.shown(value)) ?? Decimal(value))
        }

        func box() -> Node {
            Node(ScoreGate.shown(value), Tag(value == value.rounded() ? .int : .float))
        }
    }

    /// A whole number in `range`, or nil if `key` isn't set. Throws on any other value, so a typo is a configuration
    /// error rather than "unset".
    private static func whole(
        forKey key: CodingKeys,
        in range: ClosedRange<Int>,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int? {
        guard let value = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard range.contains(value) else {
            let bounds = range.upperBound == Int.max
                ? "at least \(range.lowerBound)" : "from \(range.lowerBound) to \(range.upperBound)"
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a whole number \(bounds), not \(value)"
            )
        }
        return value
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

    /// This configuration with a mutant's run going to its end, past its first failed test (`runsGoToTheirEnd`).
    func goingToEachRunsEnd() -> MuterConfiguration {
        var copy = self
        copy.runsGoToTheirEnd = true
        return copy
    }

    /// Whether every mutant's test run keeps its log: only when `keepAllLogs` is true.
    var keepsAllLogs: Bool {
        keepAllLogs == true
    }

    /// When a test is suspect, from `suspectTestFilePercent` and `suspectTestMinimumFiles`.
    var suspectTestThresholds: SuspectTestThresholds {
        SuspectTestThresholds(
            filePercent: suspectTestFilePercent ?? SuspectTestThresholds.standard.filePercent,
            minimumFiles: suspectTestMinimumFiles ?? SuspectTestThresholds.standard.minimumFiles
        )
    }

    /// A number of seconds, written as an Int or a Double, or nil if `key` isn't set.
    private static func seconds(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        try container.decodeIfPresent(Double.self, forKey: key)
            ?? (try container.decodeIfPresent(Int.self, forKey: key)).flatMap(Double.init)
    }

    /// The most workers a SwiftPM run uses when `mutationTestWorkers` doesn't say. On SwiftProjectLint on an 18-core
    /// Mac on 31 October, 2 workers took 39 min, 3 took 30, 4 took 27, 6 took 24 and 8 took 24, where two runs with 4
    /// differed by 13%, and only 8 showed clearly more false kills from tests that share state (#70).
    static let mostDefaultWorkers = 4

    /// How many mutants a SwiftPM run with no `mutationTestWorkers` tests for each clone it makes. A clone costs about
    /// a baseline build, which only enough mutants pay back. On SwiftProjectLint a clone took about 25 s, and took the
    /// wall time of a mutant from about 0.9 s with 2 workers to 0.7 s with 3 and 0.6 s with 4 (#70):
    /// about 100 mutants pay for the third worker, and about 150 for the third and fourth together.
    static let mutantsForEachDefaultWorker = 50

    /// The most mutants to test at once, however many there are to test: `mutationTestWorkers`, at least 1, or else
    /// `defaultWorkerCount`, for a SwiftPM project and for an xcodebuild
    /// project whose first `-destination` is a simulator; always 1 for the others, for the reason
    /// `parallelWorkersUnsupportedReason` gives. An xcodebuild run that can't give each worker a simulator still tests
    /// one mutant at a time (see `SimulatorWorkerSetup`), and one xcodebuild worker may test on a simulator of its own
    /// (`oneWorkerSimulator`).
    var workerCount: Int {
        guard parallelWorkersUnsupportedReason == nil else { return 1 }
        return max(1, mutationTestWorkers ?? defaultWorkerCount)
    }

    /// How many mutants a run tests at once when `mutationTestWorkers` doesn't say: on a SwiftPM project, half the
    /// processors, as each worker's tests already run in parallel, and at most `mostDefaultWorkers`. Otherwise 1: an
    /// xcodebuild worker needs a simulator of its own, which takes about 3 GB at its peak.
    var defaultWorkerCount: Int {
        guard buildSystem == .swift else { return 1 }
        return max(1, min(Self.mostDefaultWorkers, dependency(\.processorCount) / 2))
    }

    /// The number of mutants to test at once when `mutants` are to test, never more than they are: `workerCount`, or,
    /// when `mutationTestWorkers` doesn't say and each worker past the first needs a clone, only as many as they pay
    /// back (`mutantsForEachDefaultWorker`). Workers `sharingBuild` have no such cost to pay back.
    func workerCount(testing mutants: Int, sharingBuild: Bool = false) -> Int {
        guard mutationTestWorkers == nil, !sharingBuild else { return min(workerCount, mutants) }
        return min(workerCount, 1 + mutants / Self.mutantsForEachDefaultWorker, mutants)
    }

    /// Why this test command can't test more than one mutant at once, completing a sentence such as "Testing one
    /// mutant at a time: …", or nil when it can. xcodebuild can only on a simulator, as each worker gets one of its
    /// own; a destination that names one by its `id=` alone is looked up when the run starts.
    var parallelWorkersUnsupportedReason: String? {
        switch buildSystem {
        case .swift:
            return nil
        case .unknown:
            return "only SwiftPM projects, and xcodebuild projects that test on a simulator, test more than one at once"
        case .xcodebuild:
            guard let destination = firstDestination else {
                return "an xcodebuild project tests more than one at once only on a simulator, and the test command "
                    + "gives no `-destination`"
            }
            if SimulatorDestination(destination: destination) != nil {
                return nil
            }
            if Self.namesAMac(destination) {
                return "a Mac app's test runs share its UserDefaults, saved state and container, so workers would "
                    + "see each other's"
            }
            return "an xcodebuild project tests more than one at once only on a simulator, which "
                + "`-destination \(destination)` doesn't name"
        }
    }

    /// Whether `destination`, a `-destination` value, names a Mac: `platform=macOS`, with or without an `arch=` or
    /// Mac Catalyst's `variant=`.
    private static func namesAMac(_ destination: String) -> Bool {
        destination.split(separator: ",").contains { pair in
            let keyAndValue = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmed.lowercased() }
            return keyAndValue.count == 2 && keyAndValue[0] == "platform" && keyAndValue[1].hasPrefix("mac")
        }
    }

    /// How the test command's own arguments set xcodebuild's parallel testing. They reach only the baseline and the
    /// coverage run, never a mutant's, which tests from the `.xctestrun` with arguments of its own
    /// (`testWithoutBuildArguments`), so they say only how far the baseline's testing is like a mutant's.
    enum ParallelTestingArguments: Equatable {
        /// They don't set it: the scheme or the test plan does, for the baseline and the mutants' runs alike.
        case unset
        /// `-parallel-testing-enabled NO`: the baseline tests one test at a time.
        case off
        /// They set it with `option`, such as `-parallel-testing-worker-count`, which a mutant's run doesn't have.
        case tuned(String)
    }

    /// How the test command's arguments set parallel testing: `.off` for a `-parallel-testing-enabled NO`, in any
    /// case, wherever it is; else `.tuned` with the first that tunes it, `-parallel-testing-enabled YES`,
    /// `-parallel-testing-worker-count`, `-maximum-parallel-testing-workers` or
    /// `-parallelize-tests-among-destinations`; else `.unset`, as for a `-parallel-testing-enabled` with no value.
    var parallelTestingArguments: ParallelTestingArguments {
        let arguments = testCommandArguments
        var tuned: String?
        for (index, argument) in arguments.enumerated() {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "-parallel-testing-enabled":
                if let value, value.lowercased() == "no" {
                    return .off
                }
                if let value, value.lowercased() == "yes" {
                    tuned = tuned ?? "\(argument) \(value)"
                }
            case "-parallel-testing-worker-count",
                 "-maximum-parallel-testing-workers",
                 "-parallelize-tests-among-destinations":
                tuned = tuned ?? argument
            default:
                break
            }
        }
        return tuned.map(ParallelTestingArguments.tuned) ?? .unset
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

    /// Whether mutants' test runs stop at their first failed test: unless `stopAtFirstFailure` is false,
    /// whenever this test command supports it and failed-test lines are reliable. Baselines never do.
    /// On by default since an A/B run on SwiftProjectLint (255 mutants, 4 workers) took 37% less time and
    /// the switch changed no mutant's verdict. A mutant that both fails a test and crashes can be reported
    /// killed by a test failure rather than by a runtime error, depending on which comes first.
    var stopsAtFirstFailure: Bool {
        stopAtFirstFailureUnsupportedReason == nil && failedTestLinesAreReliable && (stopAtFirstFailure ?? true)
    }

    /// This configuration with `failedTestLinesAreReliable` false, and the tests that the passing runs' `testLogs`
    /// show failing added to `failedTestLookalikes`.
    func withUnreliableFailedTestLines(printedIn testLogs: [String] = []) -> MuterConfiguration {
        var copy = self
        copy.failedTestLinesAreReliable = false
        for testLog in testLogs {
            copy.failedTestLookalikes.formUnion(FailedTestLine.failedTestIdentities(inLog: testLog))
        }
        return copy
    }

    /// This configuration with `stopAtFirstFailure` false, so a mutant's test run goes on after its first failed test.
    func withoutStoppingAtFirstFailure() -> MuterConfiguration {
        var copy = self
        copy.stopAtFirstFailure = false
        return copy
    }

    /// This configuration with mutants' test runs starting the test bundles as `directTestRun` says.
    func withDirectTestRun(_ directTestRun: DirectTestRun) -> MuterConfiguration {
        var copy = self
        copy.directTestRun = directTestRun
        return copy
    }

    /// This configuration with its runs testing only what `propertyTestFilter` selects: `swift test`, and the test
    /// bundles run directly, with `--filter` for each entry, and xcodebuild with `-only-testing:`. nil without a
    /// filter, or for a build system that takes neither (`propertyRerunsUnsupportedReason`).
    func withPropertyTestFilter() -> MuterConfiguration? {
        guard let filter = propertyTestFilter, !filter.isEmpty, propertyRerunsUnsupportedReason == nil else {
            return nil
        }
        var copy = self
        switch buildSystem {
        case .swift:
            copy.testFilterArguments = filter.flatMap { ["--filter", $0] }
            copy.directTestRun = directTestRun?.adding(copy.testFilterArguments)
        case .xcodebuild:
            copy.testFilterArguments = filter.map { "-only-testing:\($0)" }
        case .unknown:
            return nil
        }
        return copy
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

    /// This configuration with an xcodebuild mutant's runs testing as `worker` says.
    func forXcodeWorker(_ worker: XcodeWorker) -> MuterConfiguration {
        var copy = self
        copy.xcodeWorker = worker
        return copy
    }

    /// This configuration with `--workers`', `--timeout`'s, `--build-timeout`'s, `--fail-under`'s, `--property-tests`'
    /// and `--report`'s values, when given, in place of `mutationTestWorkers`, `mutationTestTimeout`, `buildTimeout`,
    /// `failUnder`, `propertyTests` and `reports`, and `--exclude`'s entries after `exclude`'s: a run records and
    /// compares them as it does the keys.
    func overriding(
        workers: Int?,
        timeout: Double?,
        buildTimeout: Double? = nil,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        reports: [ReportRequest]? = nil,
        exclude: [String] = []
    ) -> MuterConfiguration {
        var copy = self
        copy.excludeFileList += exclude
        if let workers { copy.mutationTestWorkers = workers }
        if let timeout { copy.testSuiteTimeout = timeout }
        if let buildTimeout { copy.buildTimeout = buildTimeout }
        if let failUnder { copy.failUnder = failUnder }
        if let propertyTests { copy.propertyTests = propertyTests }
        if let reports { copy.reports = reports }
        return copy
    }

    /// This configuration with `exclude`'s entries sorted, once each, which choose the same files in any order.
    var withExcludesInOrder: MuterConfiguration {
        var copy = self
        copy.excludeFileList = Set(excludeFileList).sorted()
        return copy
    }

    /// This configuration with `testSuiteTimeout` set to `timeout`, unless it already has one.
    func withDefaultTestSuiteTimeout(_ timeout: TimeInterval) -> MuterConfiguration {
        guard testSuiteTimeout == nil else { return self }
        var copy = self
        copy.testSuiteTimeout = timeout
        return copy
    }

    init(from data: Data) throws {
        do {
            self = try YAMLDecoder().decode(MuterConfiguration.self, from: data)
        } catch {
            let yamlError = error
            do {
                self = try JSONDecoder().decode(MuterConfiguration.self, from: data)
            } catch {
                // YAML's reason, which names the key at fault, rather than that the file isn't JSON.
                throw yamlError
            }
        }
    }
}

extension MuterConfiguration {
    /// A copy of this configuration whose test command runs `executable`.
    func withExecutable(_ executable: String) -> MuterConfiguration {
        var copy = self
        copy.testCommandExecutable = executable
        return copy
    }
}

extension MuterConfiguration {
    static let fileName = "muter.conf"
    static let `extension` = "yml"
    static let fileNameWithExtension = "\(fileName).\(`extension`)"
    static let legacyFileNameWithExtension = "\(fileName).json"
}

extension MuterConfiguration {
    var asData: Data {
        get throws {
            Data(try YAMLEncoder().encode(self).utf8)
        }
    }
}

extension MuterConfiguration {
    /// Coverage counts each run of a piece of code by loading its counter and storing one more, so code that runs on
    /// two threads at once loses runs: Swift Testing runs tests in parallel, and a test can run code concurrently
    /// itself. A count worked out from two others, such as the code after a `guard`, then reads 0 though the code ran,
    /// and its mutants are left out. Atomic counters keep every run. On SwiftProjectLint they made the coverage run's
    /// tests take 9.3 s rather than 7.2 s; running the tests one at a time took 11.4 s and still lost counts.
    static let atomicCoverageCountersFlags = ["-Xllvm", "-instrprof-atomic-counter-update-all"]

    var enableCoverageArguments: [String] {
        var arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            // A setting given twice takes the second, so a project's own `OTHER_SWIFT_FLAGS=…` gets the flags added.
            let flags = Self.atomicCoverageCountersFlags.joined(separator: " ")
            if let index = arguments.firstIndex(where: { $0.hasPrefix("OTHER_SWIFT_FLAGS=") }) {
                arguments[index] += " " + flags
            } else {
                arguments.append("OTHER_SWIFT_FLAGS=$(inherited) " + flags)
            }
            return arguments + ["-enableCodeCoverage", "YES"]
        case .swift:
            return arguments + ["--enable-code-coverage"]
                + Self.atomicCoverageCountersFlags.flatMap { ["-Xswiftc", $0] }

        case .unknown:
            return arguments
        }
    }

    var buildForTestingArguments: [String] {
        let arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            return testArgumentsWithtDerivedData() + ["clean", "build-for-testing"]
        case .swift,
             .unknown:
            return arguments
        }
    }

    /// `buildForTestingArguments` for a build after one that failed, which only what changed needs: without the `clean`
    /// that adds, and any argument of the test command's own that says the same is left alone.
    var rebuildForTestingArguments: [String] {
        Array(buildForTestingArguments.dropLast(2)) + ["build-for-testing"]
    }

    var derivedDataPath: String {
        guard let index = derivedDataArgumentIndex() else {
            return defaultDerivedData
        }

        return testCommandArguments[index + 1]
    }

    private var defaultDerivedData: String { "DerivedData" }

    /// The test command's arguments for a run on the build the baseline made: a mutant's, or the one that times them
    /// with no mutant on. For SwiftPM they skip the build, and add `--quiet` unless `arguments` already set how much
    /// to print. `swift test` passes it on to Swift Testing, as the direct runs' script passes it to its helper (see
    /// `DirectTestRun`), which then prints no line for each test or suite that starts or passes: on SwiftProjectLint,
    /// more than 10,000 of a surviving mutant's 12,500 lines. It still prints every line SwiftMutator reads: each
    /// recorded issue, the run's summary, the tests' own output, and SwiftPM's lines for a crash. XCTest's output
    /// doesn't change. For xcodebuild they test from `testRunFile` on the first `-destination`, unless `xcodeWorker`
    /// names another file or destination, and add the worker's own arguments.
    func testWithoutBuildArguments(with testRunFile: String) -> [String] {
        let arguments = testCommandArguments
        switch buildSystem {
        case .xcodebuild:
            guard let destination = xcodeWorker?.destination ?? firstDestination else {
                return arguments
            }
            return [
                "test-without-building",
                "-destination",
                destination,
                "-xctestrun",
                xcodeWorker?.testRunFile ?? testRunFile,
            ] + (xcodeWorker?.arguments ?? []) + testFilterArguments
        case .swift:
            let setsVerbosity = arguments.contains { Self.verbosityOptions.contains($0) }
            return arguments + ["--skip-build"] + (setsVerbosity ? [] : ["--quiet"]) + testFilterArguments
        case .unknown:
            return arguments
        }
    }

    /// The value of the test command's first `-destination`, or nil if it gives none.
    var firstDestination: String? {
        indexOfArgument("-destination").flatMap { index in
            index + 1 < testCommandArguments.count ? testCommandArguments[index + 1] : nil
        }
    }

    /// `swift test`'s options that say how much it, and Swift Testing, print.
    private static let verbosityOptions: Set = ["-q", "--quiet", "-v", "--verbose", "--very-verbose", "--vv"]

    private func indexOfArgument(_ arg: String) -> Int? {
        testCommandArguments.firstIndex(of: arg)
    }

    private func derivedDataArgumentIndex() -> Int? {
        indexOfArgument("-derivedDataPath")
    }

    private func testArgumentsWithtDerivedData() -> [String] {
        guard derivedDataArgumentIndex() == nil else {
            return testCommandArguments
        }

        guard let testArgsIndex = indexOfArgument("test") else {
            return testCommandArguments
        }

        var args = testCommandArguments
        args.remove(at: testArgsIndex)
        args.append("-derivedDataPath")
        args.append(defaultDerivedData)

        return args
    }
}

extension MuterConfiguration {
    /// What one worker's xcodebuild mutant runs test from and write to, beyond the test command's own arguments.
    struct XcodeWorker: Sendable, Equatable {
        /// The `.xctestrun` file, at the mutated project's root, that the worker's runs test from.
        let testRunFile: String
        /// The worker's derived data folder, beside the mutated project (see `derivedData(ofWorker:in:)`). Without it,
        /// every run made a folder of its own in `~/Library/Developer/Xcode/DerivedData`: 3-67 MB each.
        let derivedData: String
        /// The `-destination` the worker's runs test on; nil for the test command's first.
        let destination: String?
        /// Whether the worker's runs test one test at a time, in one test process.
        let parallelTestingOff: Bool
        /// Whether the worker's runs pass `-collect-test-diagnostics never`, so a failing run doesn't spend seconds
        /// collecting diagnostics no one reads. Only when the xcodebuild in use lists the option in its `-help`: one
        /// that doesn't know it would fail every run.
        let testDiagnosticsOff: Bool

        init(
            testRunFile: String,
            derivedData: String,
            destination: String? = nil,
            parallelTestingOff: Bool = false,
            testDiagnosticsOff: Bool
        ) {
            self.testRunFile = testRunFile
            self.derivedData = derivedData
            self.destination = destination
            self.parallelTestingOff = parallelTestingOff
            self.testDiagnosticsOff = testDiagnosticsOff
        }

        /// Worker `worker`'s derived data folder, beside the mutated project, so neither the copy's fingerprint nor the
        /// build it tests from sees it: `<stem>.DerivedData.noindex` for worker 0, and
        /// `<stem>_worker<n>.DerivedData.noindex` for worker n (`MutatedProjectNames.derivedData(ofWorker:in:)`).
        static func derivedData(ofWorker worker: Int, in mutatedProject: URL) -> String {
            MutatedProjectNames.derivedData(ofWorker: worker, in: mutatedProject).path
        }

        /// The arguments the worker's runs add to the test command's.
        var arguments: [String] {
            ["-derivedDataPath", derivedData]
                + (testDiagnosticsOff ? ["-collect-test-diagnostics", "never"] : [])
                + (parallelTestingOff ? ["-parallel-testing-enabled", "NO"] : [])
        }
    }
}
