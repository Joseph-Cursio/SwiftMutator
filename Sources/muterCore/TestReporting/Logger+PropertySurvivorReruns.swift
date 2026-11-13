/// What the Logger says about the property survivor reruns (`PropertySurvivorReruns`).
extension Logger {
    /// "🧪 Running the property tests again for 12 survivors whose code ran, up to 10 times each, 4 at a time. 3 more
    /// are over propertySurvivorRerunLimit."
    func propertySurvivorRerunsStarted(_ reruns: PropertySurvivorReruns) {
        let survivors = reruns.count == 1 ? "1 survivor" : "\(reruns.count) survivors"
        let times = reruns.runs == 1 ? "once" : "up to \(reruns.runs) times each"
        let atATime = reruns.count == 1 ? ""
            : reruns.workers == 1 ? ", one at a time" : ", \(reruns.workers) at a time"
        let leftOut = switch reruns.leftOut {
        case 0: ""
        case 1: " 1 more is over propertySurvivorRerunLimit."
        default: " \(reruns.leftOut) more are over propertySurvivorRerunLimit."
        }
        print("🧪 Running the property tests again for \(survivors) whose code ran, \(times)\(atATime).\(leftOut)")
    }

    /// "🧪 Ran the property tests again for 12 survivors: a property test failed on a later run for 3, and every one
    /// of 10 runs passed for 9. They stay survivors in the score."
    func propertySurvivorRerunsFinished(_ tally: PropertySurvivorRerunTally) {
        let survivors = tally.finished == 1 ? "1 survivor" : "\(tally.finished) survivors"
        let runs = tally.reruns.runs == 1 ? "the 1 run" : "every one of \(tally.reruns.runs) runs"
        var sentence = "🧪 Ran the property tests again for \(survivors): a property test failed on a later run for "
            + "\(tally.failed), and \(runs) passed for \(tally.passed)"
        if tally.unsettled > 0 {
            sentence += "; \(tally.unsettled) timed out or didn't build, which settles nothing"
        }
        print(sentence + ". They stay survivors in the score.")
    }

    /// "⚠️ No survivor was tested again with the property tests alone: …. Its log is property tests with no mutant
    /// on.log."
    func propertySurvivorRerunsSkipped(reason: String, log: String?) {
        let logSentence = log.map { " Its log is \($0)." } ?? ""
        print("⚠️ No survivor was tested again with the property tests alone: \(reason).\(logSentence)")
    }
}
