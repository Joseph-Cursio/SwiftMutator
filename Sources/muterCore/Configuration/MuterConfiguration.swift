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
    let coverageThreshold: Double
    // A `var` only so `withDefaultTestSuiteTimeout` can copy `self` and change just this field.
    // Rebuilding with `init` instead silently resets any field the call leaves out, as every parameter
    // has a default.
    private(set) var testSuiteTimeout: Double?
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
    /// passing baseline has printed such a line, as its tests print text shaped like a failure. Such a line
    /// then neither stops a mutant's run nor counts a timed-out run killed. A `var` only so
    /// `withUnreliableFailedTestLines` can copy `self` and change just this field.
    private(set) var failedTestLinesAreReliable = true

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
        stopAtFirstFailure: Bool? = nil
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        testCommandExecutable = try container.decode(String.self, forKey: .testCommandExecutable)
        testCommandArguments = try container.decode([String].self, forKey: .testCommandArguments)

        excludeFileList = container.decode([String].self, default: [], forKey: .excludeFileList)
        excludeCallList = container.decode([String].self, default: [], forKey: .excludeCallList)
        coverageThreshold = container.decode(Double.self, default: 0, forKey: .coverageThreshold)
        testSuiteTimeout = try container.decodeIfPresent(Double.self, forKey: .testSuiteTimeout)
            ?? (try container.decodeIfPresent(Int.self, forKey: .testSuiteTimeout)).flatMap(Double.init)
        explicitBuildSystem = (try container.decodeIfPresent(String.self, forKey: .explicitBuildSystem))
            .map(BuildSystem.init(rawValue:))
        mutationTestWorkers = try container.decodeIfPresent(Int.self, forKey: .mutationTestWorkers)
        // Throws on a value that isn't a Boolean, so a typo is a configuration error rather than "unset".
        stopAtFirstFailure = try container.decodeIfPresent(Bool.self, forKey: .stopAtFirstFailure)
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

    /// Whether mutants' test runs stop at their first failed test: only when `stopAtFirstFailure` is
    /// set, this test command supports it, and failed-test lines are reliable. Baselines never do.
    var stopsAtFirstFailure: Bool {
        stopAtFirstFailureUnsupportedReason == nil && failedTestLinesAreReliable && (stopAtFirstFailure ?? false)
    }

    /// This configuration with `failedTestLinesAreReliable` false.
    func withUnreliableFailedTestLines() -> MuterConfiguration {
        var copy = self
        copy.failedTestLinesAreReliable = false
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
    var enableCoverageArguments: [String] {
        let arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            return arguments + ["-enableCodeCoverage", "YES"]
        case .swift:
            return arguments + ["--enable-code-coverage"]

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
