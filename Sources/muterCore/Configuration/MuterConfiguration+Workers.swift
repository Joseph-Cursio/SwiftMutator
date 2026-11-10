import Foundation
import Yams

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
}
