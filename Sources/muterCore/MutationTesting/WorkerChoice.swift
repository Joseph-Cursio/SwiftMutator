import Foundation

/// How many workers a run tests its mutants on, against how many it was asked for (`--workers`, or else
/// `mutationTestWorkers`), and why it uses fewer.
struct WorkerChoice: Equatable {
    /// `--workers`, or else `mutationTestWorkers`; 1 when neither is given.
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

    /// The choice for `configuration`, with `unsupportedReason`, if given, in place of the configuration's own.
    init(_ configuration: MuterConfiguration, used: Int, mutantsToTest: Int, unsupportedReason: String? = nil) {
        asked = configuration.mutationTestWorkers ?? 1
        self.used = used
        self.unsupportedReason = unsupportedReason ?? configuration.parallelWorkersUnsupportedReason
        self.mutantsToTest = mutantsToTest
        onSimulators = configuration.buildSystem == .xcodebuild
    }

    init(asked: Int, used: Int, unsupportedReason: String?, mutantsToTest: Int, onSimulators: Bool = false) {
        self.asked = asked
        self.used = used
        self.unsupportedReason = unsupportedReason
        self.mutantsToTest = mutantsToTest
        self.onSimulators = onSimulators
    }

    /// What the run says of it; nil for one worker that was all it was asked for.
    var sentence: String? {
        let testing = used == 1 ? "Testing one mutant at a time" : "Testing \(used) mutants at a time"
        guard used < asked else {
            let own = onSimulators ? "on a simulator" : "in a copy of the project"
            return used > 1 ? "👷 \(testing), each \(own) of its own." : nil
        }
        // Otherwise a run uses as many as asked for, but for more than it has mutants to test.
        let why = unsupportedReason
            ?? (mutantsToTest == 1 ? "only 1 is left to test" : "only \(mutantsToTest) are left to test")
        return "👷 \(testing), though \(asked) workers were asked for: \(why)."
    }
}
