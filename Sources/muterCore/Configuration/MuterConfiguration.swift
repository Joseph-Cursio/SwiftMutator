import Foundation
import Yams

struct MuterConfiguration: Equatable, Codable {
    let testCommandArguments: [String]
    // A `var` only so `withExecutable` can copy `self` and change just this field. Rebuilding with
    // `init` instead silently resets any field the call leaves out, as every parameter has a default.
    private(set) var testCommandExecutable: String
    /// File exclusion list.
    let excludeFileList: [String]
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
    /// Seconds before the coverage run, whose `swift test` or `xcodebuild` also builds the project, is stopped
    /// (`buildTimeout:`); nil, the default, sets no limit. For now it limits only the coverage run, but it is meant
    /// for every step that builds, such as the baseline.
    let buildTimeout: Double?
    /// How many mutants to test at once (`mutationTestWorkers:`). A SwiftPM worker runs the test command in its own
    /// clone of the mutated project, because `swift test` locks the package's build directory. Each clone is built
    /// once before testing, so the paths compiled into its tests point into it. An xcodebuild worker tests on a
    /// simulator of its own, from the mutated project's one build (see `XcodeWorker`). Other projects, and xcodebuild
    /// projects that test elsewhere, test one at a time (`parallelWorkersUnsupportedReason`); so do nil and 1, though
    /// one xcodebuild worker may still test on a simulator of its own (`oneWorkerSimulator`). A `var` only so
    /// `overriding` can copy `self` and change just this field.
    private(set) var mutationTestWorkers: Int?
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
    /// nil leaves each to `SuspectTestThresholds.standard`. They change only what the reports say, never a mutant's
    /// result, so a resume lets them change (`ResumeCheck.keysThatDontAffectOutcomes`).
    let suspectTestFilePercent: Int?
    let suspectTestMinimumFiles: Int?
    /// How many mutants to test for each control run, a run with no mutant on among theirs (`controlRunEvery:`, a
    /// whole number, 0 for none): nil leaves it to `defaultMutantsPerControlRun`. A control run changes no mutant's
    /// result, only which tests the reports call suspect, so a resume lets it change.
    let controlRunEvery: Int?
    /// Whether every mutant's test run keeps its log (`keepAllLogs:`): nil and false keep a mutant's log only when its
    /// results line can't stand in for it, true keeps every log. See `MutationTestLog.isKept`. Which logs are kept
    /// changes no result, so a resume lets it change.
    let keepAllLogs: Bool?
    /// How many runs' log folders to keep in `<project>_muter_logs` (`keepLogFolders:`, a whole number, at least 2),
    /// this run's included, so the run before it is always kept; nil, the default, removes none. A run's folders are
    /// those of each of its sessions, and only a run with a results file counts. See `LogFolderPruning`. Which folders
    /// are kept changes no result, so a resume lets it change.
    let keepLogFolders: Int?
    /// Whether a line `FailedTestLine` matches shows a failed test. Not a configuration key: false once a
    /// passing baseline has printed such a line, or one `CrashLine` matches, as its tests print text shaped like a
    /// failure. Such a line then neither stops a mutant's run nor counts a timed-out run killed. A `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    private(set) var failedTestLinesAreReliable = true
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

    var buildSystem: BuildSystem {
        if let explicitBuildSystem, explicitBuildSystem != .unknown {
            return explicitBuildSystem
        }

        guard let buildSystem = testCommandExecutable.components(separatedBy: "/").last?.trimmed else {
            return .unknown
        }

        return BuildSystem(rawValue: buildSystem)
    }

    enum CodingKeys: String, CodingKey {
        case testCommandArguments = "arguments"
        case testCommandExecutable = "executable"
        case excludeFileList = "exclude"
        case excludeCallList = "excludeCalls"
        case coverageThreshold
        case testSuiteTimeout = "mutationTestTimeout"
        case buildTimeout
        case explicitBuildSystem = "buildSystem"
        case mutationTestWorkers
        case stopAtFirstFailure
        case oneWorkerSimulator
        case suspectTestFilePercent
        case suspectTestMinimumFiles
        case controlRunEvery
        case keepAllLogs
        case keepLogFolders
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
        stopAtFirstFailure: Bool? = nil,
        buildTimeout: Double? = nil,
        oneWorkerSimulator: Bool? = nil,
        suspectTestFilePercent: Int? = nil,
        suspectTestMinimumFiles: Int? = nil,
        controlRunEvery: Int? = nil,
        keepAllLogs: Bool? = nil,
        keepLogFolders: Int? = nil
    ) {
        testCommandExecutable = executable
        testCommandArguments = arguments
        excludeFileList = excludeList
        excludeCallList = callList
        coverageThreshold = threshold
        testSuiteTimeout = timeout
        explicitBuildSystem = buildSystem
        mutationTestWorkers = workers
        self.stopAtFirstFailure = stopAtFirstFailure
        self.buildTimeout = buildTimeout
        self.oneWorkerSimulator = oneWorkerSimulator
        self.suspectTestFilePercent = suspectTestFilePercent
        self.suspectTestMinimumFiles = suspectTestMinimumFiles
        self.controlRunEvery = controlRunEvery
        self.keepAllLogs = keepAllLogs
        self.keepLogFolders = keepLogFolders
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
        // Throws on a value that isn't a Boolean, so a typo is a configuration error rather than "unset".
        stopAtFirstFailure = try container.decodeIfPresent(Bool.self, forKey: .stopAtFirstFailure)
        oneWorkerSimulator = try container.decodeIfPresent(Bool.self, forKey: .oneWorkerSimulator)
        suspectTestFilePercent = try Self.whole(forKey: .suspectTestFilePercent, in: 1 ... 100, in: container)
        suspectTestMinimumFiles = try Self.whole(forKey: .suspectTestMinimumFiles, in: 1 ... Int.max, in: container)
        controlRunEvery = try Self.whole(forKey: .controlRunEvery, in: 0 ... Int.max, in: container)
        keepAllLogs = try container.decodeIfPresent(Bool.self, forKey: .keepAllLogs)
        keepLogFolders = try Self.whole(forKey: .keepLogFolders, in: 2 ... Int.max, in: container)
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

    /// The number of mutants to test at once: `mutationTestWorkers`, at least 1, for a SwiftPM project and for an
    /// xcodebuild project whose first `-destination` is a simulator; always 1 for the others, for the reason
    /// `parallelWorkersUnsupportedReason` gives. An xcodebuild run that can't give each worker a simulator still tests
    /// one mutant at a time (see `SimulatorWorkerSetup`), and one xcodebuild worker may test on a simulator of its own
    /// (`oneWorkerSimulator`).
    var workerCount: Int {
        guard parallelWorkersUnsupportedReason == nil else { return 1 }
        return max(1, mutationTestWorkers ?? 1)
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

    /// This configuration with an xcodebuild mutant's runs testing as `worker` says.
    func forXcodeWorker(_ worker: XcodeWorker) -> MuterConfiguration {
        var copy = self
        copy.xcodeWorker = worker
        return copy
    }

    /// This configuration with `--workers`' and `--timeout`'s values, when given, in place of `mutationTestWorkers` and
    /// `mutationTestTimeout`: a run records and compares them as it does the keys.
    func overriding(workers: Int?, timeout: Double?) -> MuterConfiguration {
        var copy = self
        if let workers { copy.mutationTestWorkers = workers }
        if let timeout { copy.testSuiteTimeout = timeout }
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
            self = try JSONDecoder().decode(MuterConfiguration.self, from: data)
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
            ] + (xcodeWorker?.arguments ?? [])
        case .swift:
            let setsVerbosity = arguments.contains { Self.verbosityOptions.contains($0) }
            return arguments + ["--skip-build"] + (setsVerbosity ? [] : ["--quiet"])
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

        /// Ends the name of a worker's derived data folder.
        static let derivedDataSuffix = ".DerivedData"

        /// Worker `worker`'s derived data folder: `<mutated>.DerivedData` for worker 0, and
        /// `<mutated>_worker<n>.DerivedData` for worker n, beside the mutated project, so neither the copy's
        /// fingerprint nor the build it tests from sees it.
        static func derivedData(ofWorker worker: Int, in mutatedProject: URL) -> String {
            let folder = mutatedProject.lastPathComponent + (worker == 0 ? "" : "_worker\(worker)")
            return mutatedProject.deletingLastPathComponent()
                .appendingPathComponent(folder + derivedDataSuffix)
                .path
        }

        /// The arguments the worker's runs add to the test command's.
        var arguments: [String] {
            ["-derivedDataPath", derivedData]
                + (testDiagnosticsOff ? ["-collect-test-diagnostics", "never"] : [])
                + (parallelTestingOff ? ["-parallel-testing-enabled", "NO"] : [])
        }
    }
}
