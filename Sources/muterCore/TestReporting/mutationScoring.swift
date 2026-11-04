/// The mutants `testResults` kill, by a failed test or a crash, and those scored: every one but a build error.
func scoredMutants(in testResults: [TestSuiteOutcome]) -> (killed: Int, scored: Int) {
    (
        killed: testResults.count { $0 == .failed || $0 == .runtimeError },
        scored: testResults.count { $0 != .buildError }
    )
}

/// The headline score, exactly: the mutants killed, by a failed test or a crash, as a percent of those scored, every
/// one but a build error; nil when none was scored. The reports truncate it to a whole percent
/// (`mutationScore(from:)`), and `ScoreGate` compares it whole, so a change in how the score is shown can't change a
/// verdict.
func exactMutationScore(from testResults: [TestSuiteOutcome]) -> Double? {
    let mutants = scoredMutants(in: testResults)
    return exactMutationScore(killed: mutants.killed, of: mutants.scored)
}

/// `killed` as a percent of `scored`; nil when `scored` is 0. It multiplies before it divides, so a score that is a
/// whole percent comes out exactly: 29 of 50 is 58, where 29 / 50 * 100 is 57.99999999999999.
func exactMutationScore(killed: Int, of scored: Int) -> Double? {
    scored > 0 ? Double(killed * 100) / Double(scored) : nil
}

/// The headline score as every report gives it: `exactMutationScore(from:)` truncated to a whole percent. 0 when every
/// result is a build error, and -1 when there is none.
func mutationScore(from testResults: [TestSuiteOutcome]) -> Int {
    guard !testResults.isEmpty else {
        return -1
    }
    return exactMutationScore(from: testResults).map { Int($0) } ?? 0
}

func mutationScoresOfFiles(from outcomes: [MutationTestOutcome.Mutation]) -> [String: Int] {
    var mutationScores: [String: Int] = [:]

    let filePaths = outcomes.map { $0.point.filePath }.deduplicated()
    for filePath in filePaths {
        let testSuiteOutcomes = outcomes.include { $0.point.filePath == filePath }.map { $0.testSuiteOutcome }
        mutationScores[filePath] = mutationScore(from: testSuiteOutcomes)
    }

    return mutationScores
}
