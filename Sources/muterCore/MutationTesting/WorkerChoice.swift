import Foundation

/// How many workers a run tests its mutants on, against how many it was asked for (`--workers`, or else
/// `mutationTestWorkers`), and why it uses fewer.
struct WorkerChoice: Equatable {
    /// `--workers`, or else `mutationTestWorkers`; 1 when neither is given.
    let asked: Int
    let used: Int
    let isSwiftPM: Bool
    let mutantsToTest: Int

    init(_ configuration: MuterConfiguration, used: Int, mutantsToTest: Int) {
        asked = configuration.mutationTestWorkers ?? 1
        self.used = used
        isSwiftPM = configuration.buildSystem == .swift
        self.mutantsToTest = mutantsToTest
    }

    init(asked: Int, used: Int, isSwiftPM: Bool, mutantsToTest: Int) {
        self.asked = asked
        self.used = used
        self.isSwiftPM = isSwiftPM
        self.mutantsToTest = mutantsToTest
    }

    /// What the run says of it; nil for one worker that was all it was asked for.
    var sentence: String? {
        let testing = used == 1 ? "Testing one mutant at a time" : "Testing \(used) mutants at a time"
        guard used < asked else {
            return used > 1 ? "👷 \(testing), each in a copy of the project of its own." : nil
        }
        // A SwiftPM project uses as many as asked for, but for more than it has mutants to test.
        let why = !isSwiftPM
            ? "only SwiftPM projects test more than one at once"
            : mutantsToTest == 1 ? "only 1 is left to test" : "only \(mutantsToTest) are left to test"
        return "👷 \(testing), though \(asked) workers were asked for: \(why)."
    }
}
