import Foundation

/// What a tested mutant came to, as the progress lines and the reports count it. The score counts a crash as a kill,
/// and a timeout or a mutant not covered as a survivor.
enum MutantVerdict: CaseIterable {
    case killed
    case survived
    case timedOut
    case buildError
    case notCovered

    init(_ outcome: TestSuiteOutcome) {
        switch outcome {
        case .failed, .runtimeError: self = .killed
        case .passed: self = .survived
        case .timeout: self = .timedOut
        case .buildError: self = .buildError
        case .noCoverage: self = .notCovered
        }
    }

    /// What `count` mutants came to: "killed", or "build errors".
    func words(_ count: Int) -> String {
        switch self {
        case .killed: return "killed"
        case .survived: return "survived"
        case .timedOut: return "timed out"
        case .buildError: return count == 1 ? "build error" : "build errors"
        case .notCovered: return "not covered"
        }
    }
}

/// How many mutants came to each `MutantVerdict`. The JSON report holds it as `mutantsByOutcome`.
struct OutcomeCounts: Codable, Equatable {
    let killed: Int
    let survived: Int
    let timedOut: Int
    let buildErrors: Int
    let notCovered: Int

    init(killed: Int = 0, survived: Int = 0, timedOut: Int = 0, buildErrors: Int = 0, notCovered: Int = 0) {
        self.killed = killed
        self.survived = survived
        self.timedOut = timedOut
        self.buildErrors = buildErrors
        self.notCovered = notCovered
    }

    init(_ outcomes: some Sequence<TestSuiteOutcome>) {
        var counts: [MutantVerdict: Int] = [:]
        for outcome in outcomes {
            counts[MutantVerdict(outcome), default: 0] += 1
        }
        self.init(
            killed: counts[.killed] ?? 0,
            survived: counts[.survived] ?? 0,
            timedOut: counts[.timedOut] ?? 0,
            buildErrors: counts[.buildError] ?? 0,
            notCovered: counts[.notCovered] ?? 0
        )
    }

    func count(of verdict: MutantVerdict) -> Int {
        switch verdict {
        case .killed: killed
        case .survived: survived
        case .timedOut: timedOut
        case .buildError: buildErrors
        case .notCovered: notCovered
        }
    }

    /// "98 killed, 15 survived, 4 timed out, 3 build errors": each verdict some mutant came to, in that order, as the
    /// progress lines give them; "no mutants" when there are none.
    var tally: String {
        let parts = MutantVerdict.allCases.compactMap { verdict -> String? in
            let count = count(of: verdict)
            return count > 0 ? "\(count) \(verdict.words(count))" : nil
        }
        return parts.isEmpty ? "no mutants" : parts.joined(separator: ", ")
    }
}
