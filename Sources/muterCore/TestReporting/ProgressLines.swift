import Foundation

/// The progress a log file or a pipe gets in place of the progress bar, whose redraws move the cursor up: a line once
/// the baseline passes, then one as each mutant finishes. Each says when, how many mutants are tested and the time
/// left, and from the second on, what they came to and the mutant, as in this line, here split in two:
///
///     [13:13:25] 1103 of 2497 (44%) | 838 killed, 262 survived, 3 timed out | 47 min left
///     | survived at Rules.swift:42:17 (changed == to !=)
///
/// While no mutant finishes for a minute, a line each minute names the mutants under way, so that a hung run doesn't
/// look like a slow one (`Heartbeat`):
///
///     [13:20:05] still testing | worker 1: Rules.swift:42:17 for 75 s | worker 2: Walker.swift:10:3 for 61 s
///
/// No number follows "killed", so no line matches a script's `killed [0-9]+`, which looks for the report's "your test
/// suite killed 1520". No line starts with a file's place or says "warning:", which Xcode would take for an issue.
struct ProgressLines {
    /// How many mutants this session tests.
    let total: Int
    let estimate: SimpleTimeEstimate
    private(set) var tested = 0
    private var counts: [MutantVerdict: Int] = [:]

    init(total: Int, estimate: SimpleTimeEstimate) {
        self.total = total
        self.estimate = estimate
    }

    /// The line once the baseline passes, before any mutant is tested.
    func firstLine(at time: Date) -> String {
        line(at: time, mutant: nil)
    }

    /// Counts `mutant` as tested, and gives its line.
    mutating func line(after mutant: MutationTestOutcome.Mutation, at time: Date) -> String {
        let verdict = MutantVerdict(mutant.testSuiteOutcome)
        tested += 1
        counts[verdict, default: 0] += 1
        let place = "\(mutant.point.fileName):\(mutant.point.position.line):\(mutant.point.position.column)"
        let change = mutant.snapshot.description.isEmpty ? "" : " (\(mutant.snapshot.description))"
        return line(at: time, mutant: "\(verdict.words(1)) at \(place)\(change)")
    }

    /// The line that names the mutants under way, while none finishes: each one's place and how long it has run, and
    /// with more than one worker, its worker's number, from 1.
    func stillTestingLine(_ still: StillTesting, at time: Date) -> String {
        let runs = still.runs.map { run in
            let worker = still.workers > 1 ? "worker \(run.worker + 1): " : ""
            return "\(worker)\(run.place) for \(Int(run.seconds)) s"
        }
        return (["[\(Self.timeOfDay(time))] still testing"] + runs).joined(separator: " | ")
    }

    private func line(at time: Date, mutant: String?) -> String {
        let percent = total > 0 ? tested * 100 / total : 100
        var parts = ["[\(Self.timeOfDay(time))] \(tested) of \(total) (\(percent)%)"]
        let tally = MutantVerdict.allCases.compactMap { verdict in
            counts[verdict].map { "\($0) \(verdict.words($0))" }
        }
        if !tally.isEmpty {
            parts.append(tally.joined(separator: ", "))
        }
        parts.append("\(estimate.timeLeft(tested: tested, of: total)) left")
        if let mutant {
            parts.append(mutant)
        }
        return parts.joined(separator: " | ")
    }

    /// "13:13:25", in local time. The log folder's name, and each result in the results file, give the date.
    private static func timeOfDay(_ time: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
        let digits = [parts.hour, parts.minute, parts.second].map { part in
            let number = part ?? 0
            return number < 10 ? "0\(number)" : "\(number)"
        }
        return digits.joined(separator: ":")
    }
}
