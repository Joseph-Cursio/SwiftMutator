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
    /// How many mutants to test at once (`mutationTestWorkers:`). Each worker runs the test command in
    /// its own clone of the mutated project, because `swift test` locks the package's build directory.
    /// Each clone is built once before testing, so the paths compiled into its tests point into it.
    /// Only SwiftPM projects run in parallel; nil or 1 tests one mutant at a time.
    let mutationTestWorkers: Int?
    /// Optional explicit build system from the `buildSystem:` config key. When set it overrides the
    /// executable-basename heuristic — needed when `executable` is a wrapper script (e.g. one that
    /// restores env / forwards SIMCTL_CHILD_ vars) whose filename isn't literally `xcodebuild`/`swift`.
    let explicitBuildSystem: BuildSystem?
    /// Whether a mutant's test run stops at its first failed test (`stopAtFirstFailure:`), which already
    /// decides that the mutant is killed. nil leaves it to the default; see `stopsAtFirstFailure`.
    let stopAtFirstFailure: Bool?
    /// Whether a line `FailedTestLine` matches shows a failed test. Not a configuration key: false once a
    /// passing baseline has printed such a line, or one `CrashLine` matches, as its tests print text shaped like a
    /// failure. Such a line then neither stops a mutant's run nor counts a timed-out run killed. A `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    private(set) var failedTestLinesAreReliable = true
    /// How a mutant's run starts the test bundles without `swift test`. Not a configuration key: set once a run of
    /// them with no mutant on has matched the baseline (see `DirectTestRun`). A `var` only so `withDirectTestRun` can
    /// copy `self` and change just this field.
    private(set) var directTestRun: DirectTestRun?

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
        buildTimeout: Double? = nil
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
    }

    /// A number of seconds, written as an Int or a Double, or nil if `key` isn't set.
    private static func seconds(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        try container.decodeIfPresent(Double.self, forKey: key)
            ?? (try container.decodeIfPresent(Int.self, forKey: key)).flatMap(Double.init)
    }

    /// The number of mutants to test at once: `mutationTestWorkers` for a SwiftPM project, at least 1;
    /// always 1 for other build systems, whose test runs share an `.xctestrun` file and DerivedData.
    var workerCount: Int {
        guard buildSystem == .swift else { return 1 }
        return max(1, mutationTestWorkers ?? 1)
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

    /// This configuration with `failedTestLinesAreReliable` false.
    func withUnreliableFailedTestLines() -> MuterConfiguration {
        var copy = self
        copy.failedTestLinesAreReliable = false
        return copy
    }

    /// This configuration with mutants' test runs starting the test bundles as `directTestRun` says.
    func withDirectTestRun(_ directTestRun: DirectTestRun) -> MuterConfiguration {
        var copy = self
        copy.directTestRun = directTestRun
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
        let encoder = YAMLEncoder()
        return (try! encoder.encode(self)).data(using: .utf8)!
    }
}

extension MuterConfiguration {
    /// Coverage counts each run of a piece of code by loading its counter and storing one more, so code that runs on
    /// two threads at once loses runs: Swift Testing runs tests in parallel, and a test can run code concurrently itself.
    /// A count worked out from two others, such as the code after a `guard`, then reads 0 though the code ran, and its
    /// mutants are left out. Atomic counters keep every run. On SwiftProjectLint they made the coverage run's tests take
    /// 9.3 s rather than 7.2 s; running the tests one at a time took 11.4 s and still lost counts.
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

    func testWithoutBuildArguments(with testRunFile: String) -> [String] {
        let arguments = testCommandArguments
        switch buildSystem {
        case .xcodebuild:
            guard let destinationIndex = indexOfArgument("-destination") else {
                return arguments
            }
            return [
                "test-without-building",
                testCommandArguments[destinationIndex],
                testCommandArguments[destinationIndex + 1],
                "-xctestrun",
                testRunFile,
            ]
        case .swift:
            return arguments + ["--skip-build"]
        case .unknown:
            return arguments
        }
    }

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
