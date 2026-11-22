extension MuterConfiguration {
    /// The most workers a SwiftPM run uses when `mutationTestWorkers` doesn't say. On SwiftProjectLint on an 18-core
    /// Mac on 31 October, 2 workers took 39 min, 3 took 30, 4 took 27, 6 took 24 and 8 took 24, where two runs with 4
    /// differed by 13%, and only 8 showed clearly more false kills from tests that share state (#70).
    static let mostDefaultWorkers = 4

    /// How many mutants a SwiftPM run with no `mutationTestWorkers` tests for each clone it makes. A clone costs about
    /// a baseline build, which only enough mutants pay back. On SwiftProjectLint a clone took about 25 s, and took the
    /// wall time of a mutant from about 0.9 s with 2 workers to 0.7 s with 3 and 0.6 s with 4 (#70):
    /// about 100 mutants pay for the third worker, and about 150 for the third and fourth together.
    static let mutantsForEachDefaultWorker = 50

    /// The most simulators an xcodebuild run makes for its workers when `mutationTestWorkers` doesn't say. On a copy of
    /// BonMot's iOS tests, 363 mutants with parallel testing off, on an 18-core 64 GB Mac on 21 November 2026, one
    /// worker on the destination took 541 s and 525 s, 2 workers 345 s and 340 s, 3 took 309 s and 297 s, and 4 took
    /// 317 s and 312 s, every run giving every mutant the same outcome. The mutants' own phase stopped gaining at 3,
    /// while each simulator past the first took 15 to 30 s more to make, boot and check, and memory rose with each
    /// (`memoryForEachDefaultSimulatorWorker`). On MacCloud_client_iOS 2 workers took 175 to 186 s and 4 took 167 to
    /// 169 s (#194, #282).
    static let mostDefaultSimulatorWorkers = 2

    /// The memory an xcodebuild run's default count asks of the machine for each worker's simulator, so a Mac with less
    /// than 32 GiB tests one mutant at a time unless asked. On BonMot, as for `mostDefaultSimulatorWorkers`, the
    /// machine's memory in use peaked 3.1 and 3.7 GB above its idle level with one worker on the destination, 12.6 and
    /// 18.1 GB with 2 workers, 22.5 and 24.1 GB with 3, and 27.4 and 28.4 GB with 4; on MacCloud_client_iOS 9.9 to
    /// 10.8 GB with 2 and 14.9 to 17.1 GB with 4: far more for each simulator than the 3 GB once assumed.
    static let memoryForEachDefaultSimulatorWorker: UInt64 = 16 << 30

    /// How many mutants an xcodebuild run with no `mutationTestWorkers` tests for each simulator past the first. On
    /// BonMot, as for `mostDefaultSimulatorWorkers`, the second simulator cost about 29 s more before the first mutant,
    /// 36 s against 7 s, and took a mutant's share of the wall time from about 1.4 s to 0.8 s: about 50 mutants pay it
    /// back.
    static let mutantsForEachDefaultSimulatorWorker = 50

    /// The most mutants to test at once, however many there are to test: `mutationTestWorkers`, at least 1, or else
    /// `defaultWorkerCount`, for a SwiftPM project, for an xcodebuild project whose first `-destination` is a
    /// simulator, and for one whose workers test on this Mac (`testsOnMacWorkers`); always 1 for the others, for the
    /// reason `parallelWorkersUnsupportedReason` gives. An xcodebuild run that can't give each worker a simulator
    /// still tests one mutant at a time (see `SimulatorWorkerSetup`), and one xcodebuild worker may test on a simulator
    /// of its own (`oneWorkerSimulator`).
    var workerCount: Int {
        guard parallelWorkersUnsupportedReason == nil else { return 1 }
        return max(1, mutationTestWorkers ?? defaultWorkerCount)
    }

    /// How many mutants a run tests at once when `mutationTestWorkers` doesn't say: on a SwiftPM project, half the
    /// processors, as each worker's tests already run in parallel, and at most `mostDefaultWorkers`. On an xcodebuild
    /// project whose first `-destination` is a simulator, half the processors too, and no more than
    /// `memoryForEachDefaultSimulatorWorker` allows of the machine's memory, as each worker's simulator holds some, and
    /// at most `mostDefaultSimulatorWorkers`; 1 with `oneWorkerSimulator: false`, which asks for no simulator
    /// SwiftMutator makes. On an xcodebuild project whose workers test on this Mac (`testsOnMacWorkers`), as on a
    /// SwiftPM project: they need no simulator, nor a clone, only an `.xctestrun` and derived data of their own.
    /// Otherwise 1.
    var defaultWorkerCount: Int {
        switch buildSystem {
        case .swift:
            return max(1, min(Self.mostDefaultWorkers, dependency(\.processorCount) / 2))

        case .xcodebuild:
            if testsOnMacWorkers {
                return max(1, min(Self.mostDefaultWorkers, dependency(\.processorCount) / 2))
            }
            guard parallelWorkersUnsupportedReason == nil, oneWorkerSimulator != .disabled else { return 1 }
            let byMemory = Int(clamping: dependency(\.physicalMemory) / Self.memoryForEachDefaultSimulatorWorker)
            return max(1, min(Self.mostDefaultSimulatorWorkers, dependency(\.processorCount) / 2, byMemory))

        case .unknown:
            return 1
        }
    }

    /// The number of mutants to test at once when `mutants` are to test, never more than they are: `workerCount`, or,
    /// when `mutationTestWorkers` doesn't say, only as many as pay back what each worker past the first costs: a clone
    /// for SwiftPM (`mutantsForEachDefaultWorker`), a simulator for xcodebuild
    /// (`mutantsForEachDefaultSimulatorWorker`). Workers `sharingBuild`, and workers on this Mac
    /// (`testsOnMacWorkers`), have no such cost to pay back.
    func workerCount(testing mutants: Int, sharingBuild: Bool = false) -> Int {
        guard mutationTestWorkers == nil, !sharingBuild, !testsOnMacWorkers else { return min(workerCount, mutants) }
        let mutantsForEachWorker = buildSystem == .xcodebuild
            ? Self.mutantsForEachDefaultSimulatorWorker
            : Self.mutantsForEachDefaultWorker
        return min(workerCount, 1 + mutants / mutantsForEachWorker, mutants)
    }

    /// Why this test command can't test more than one mutant at once, completing a sentence such as "Testing one
    /// mutant at a time: …", or nil when it can. xcodebuild can on a simulator, as each worker gets one of its own, and
    /// on this Mac when its tests run in Xcode's `xctest` agent (`testsOnMacWorkers`); otherwise not, for the reason
    /// `simulatorWorkersUnsupportedReason` gives.
    var parallelWorkersUnsupportedReason: String? {
        testsOnMacWorkers ? nil : simulatorWorkersUnsupportedReason
    }

    /// Why this test command's workers can't each test on a simulator of their own, completing a sentence such as
    /// "Testing one mutant at a time: …", or nil when they can, or for SwiftPM, whose workers need none. xcodebuild's
    /// can only when the first `-destination` is a simulator; one that names one by its `id=` alone is looked up when
    /// the run starts. A Mac's reason holds for a Mac app's tests, UI tests and Mac Catalyst; a Mac whose tests run in
    /// Xcode's `xctest` agent tests on workers of its own all the same (`parallelWorkersUnsupportedReason`), but makes
    /// no simulator for them (`SimulatorWorkerSetup`).
    var simulatorWorkersUnsupportedReason: String? {
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
    static func namesAMac(_ destination: String) -> Bool {
        destination.split(separator: ",").contains { pair in
            let keyAndValue = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmed.lowercased() }
            return keyAndValue.count == 2 && keyAndValue[0] == "platform" && keyAndValue[1].hasPrefix("mac")
        }
    }

    /// Whether the test command's own arguments turn xcodebuild's parallel testing on or off. They reach the baseline,
    /// and a mutant's run on the test command's destination too (`testWithoutBuildArguments`), so its testing is the
    /// baseline's; a worker on a simulator of its own leaves them out, and tests one test at a time.
    enum ParallelTestingArguments: Equatable {
        /// They don't: the scheme or the test plan does, as the `.xctestrun` shows (`XCTestRun.parallelizes`). Options
        /// that only tune it, such as `-parallel-testing-worker-count`, leave it so.
        case unset
        /// `-parallel-testing-enabled NO`: the baseline, and a mutant's run on the destination, test one at a time.
        case disabled
        /// `-parallel-testing-enabled YES`, whatever the scheme or the test plan says.
        case enabled
    }

    /// How the test command's arguments set parallel testing: by their `-parallel-testing-enabled`, YES or NO in any
    /// case, which xcodebuild takes only once; else `.unset`, as for one with no value.
    var parallelTestingArguments: ParallelTestingArguments {
        let enabled = XcodebuildArguments(testCommandArguments).arguments.first {
            $0.kind == .option && $0.name == "-parallel-testing-enabled"
        }
        switch enabled?.written.dropFirst().first?.lowercased() {
        case "yes":
            return .enabled

        case "no":
            return .disabled

        default:
            return .unset
        }
    }

    /// Whether a mutant's run on the test command's destination, as the baseline's is, tests in parallel, on clones of
    /// its simulator: as the test command's arguments say (`parallelTestingArguments`), else as `xctestrun`, the
    /// project's `.xctestrun`, does (`XCTestRun.parallelizes`).
    func destinationRunsInParallel(given xctestrun: XCTestRun) -> Bool {
        switch parallelTestingArguments {
        case .unset:
            return xctestrun.parallelizes

        case .enabled:
            return true

        case .disabled:
            return false
        }
    }
}
