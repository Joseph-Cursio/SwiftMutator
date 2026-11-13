/// How many workers a run tests its mutants on, against how many it was asked for (`--workers`, or else
/// `mutationTestWorkers`), and why it uses fewer.
struct WorkerChoice: Equatable {
    /// `--workers`, or else `mutationTestWorkers`; the default count when neither is given
    /// (`MuterConfiguration.defaultWorkerCount`).
    let asked: Int
    let used: Int
    /// Why the run tests one mutant at a time whatever it was asked for: its test command can't test more than one
    /// at once (`MuterConfiguration.parallelWorkersUnsupportedReason`), or its workers' simulators couldn't be made,
    /// booted or checked. Nil when it can.
    let unsupportedReason: String?
    let mutantsToTest: Int
    /// Whether each worker tests on a simulator of its own, as an xcodebuild project's do, rather than in a copy of
    /// the project.
    let onSimulators: Bool
    /// Whether the run's workers test on simulators SwiftMutator made, a lone xcodebuild worker's included
    /// (`SimulatorWorkerSetup.Workers.xcodeWorkers`).
    let ownSimulator: Bool
    /// Whether `unsupportedReason` is the run's own, found as it set its workers up, rather than its test command's:
    /// a simulator that couldn't be made, booted or checked, or one that a lone worker didn't get.
    let fellBack: Bool
    /// Whether the count is SwiftMutator's own choice of more than one, as neither `--workers` nor
    /// `mutationTestWorkers` gave one. Fewer than that for a run of few mutants is then no surprise, and a clone that
    /// doesn't pass its baseline only makes the run test one mutant at a time.
    let isDefaultCount: Bool
    /// Whether the workers test from the mutated project's one build, rather than each in a clone.
    let sharesBuild: Bool

    /// The choice for `configuration`, with `unsupportedReason`, if given, in place of the configuration's own.
    init(
        _ configuration: MuterConfiguration,
        used: Int,
        mutantsToTest: Int,
        unsupportedReason: String? = nil,
        ownSimulator: Bool = false,
        sharesBuild: Bool = false
    ) {
        asked = configuration.mutationTestWorkers ?? configuration.defaultWorkerCount
        isDefaultCount = configuration.mutationTestWorkers == nil && configuration.defaultWorkerCount > 1
        self.sharesBuild = sharesBuild
        self.used = used
        fellBack = unsupportedReason != nil
        self.unsupportedReason = unsupportedReason ?? configuration.parallelWorkersUnsupportedReason
        self.mutantsToTest = mutantsToTest
        onSimulators = configuration.buildSystem == .xcodebuild
        self.ownSimulator = ownSimulator
    }

    init(
        asked: Int,
        used: Int,
        unsupportedReason: String?,
        mutantsToTest: Int,
        onSimulators: Bool = false,
        ownSimulator: Bool = false,
        fellBack: Bool = false,
        isDefaultCount: Bool = false,
        sharesBuild: Bool = false
    ) {
        self.asked = asked
        self.used = used
        self.unsupportedReason = unsupportedReason
        self.mutantsToTest = mutantsToTest
        self.onSimulators = onSimulators
        self.ownSimulator = ownSimulator
        self.fellBack = fellBack
        self.isDefaultCount = isDefaultCount
        self.sharesBuild = sharesBuild
    }

    /// What the run says of it. One worker that was all it was asked for is said only on a simulator of its own, or
    /// when it was to have one and fell back to the test command's destination, saying why; never for a test command
    /// that tests only where it says, such as on a Mac. Several by default say how to choose another count; a default
    /// run that fell back follows the line that said them.
    var sentence: String? {
        let testing = used == 1 ? "Testing one mutant at a time" : "Testing \(used) mutants at a time"
        if sharesBuild, used > 1 {
            let reason = "from one build, as your tests wrote nothing in the project"
            if isDefaultCount {
                return "👷 \(testing) by default, \(reason): `--workers` or `mutationTestWorkers` sets another count."
            }
            return used < asked
                ? "👷 \(testing), \(reason), though \(asked) workers were asked for: \(whyFewer)."
                : "👷 \(testing), \(reason)."
        }
        if isDefaultCount {
            if used > 1 {
                return "👷 \(testing), each in a copy of the project of its own, by default: `--workers` or "
                    + "`mutationTestWorkers` sets another count."
            }
            return fellBack ? unsupportedReason.map { "👷 \(testing) instead: \($0)." } : nil
        }
        guard used < asked else {
            if used == 1 {
                if ownSimulator {
                    return "👷 \(testing), on a simulator of its own."
                }
                if fellBack, let why = unsupportedReason {
                    return "👷 \(testing) on the test command's destination: \(why)."
                }
                return nil
            }
            let own = onSimulators ? "on a simulator" : "in a copy of the project"
            return used > 1 ? "👷 \(testing), each \(own) of its own." : nil
        }
        return "👷 \(testing), though \(asked) workers were asked for: \(whyFewer)."
    }

    /// Why fewer workers than asked for: a run uses as many, but for more than it has mutants to test.
    private var whyFewer: String {
        unsupportedReason
            ?? (mutantsToTest == 1 ? "only 1 is left to test" : "only \(mutantsToTest) are left to test")
    }
}
