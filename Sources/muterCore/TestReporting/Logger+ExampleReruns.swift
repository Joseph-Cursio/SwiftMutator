/// What the Logger says about the example reruns (`ExampleReruns`).
extension Logger {
    /// "🧪 Running every test but the property tests again for 2 kills only properties were recorded making, one at a
    /// time.": once every mutant is tested.
    func exampleRerunsStarted(_ reruns: ExampleReruns) {
        let kills = reruns.count == 1 ? "1 kill" : "\(reruns.count) kills"
        let atATime = reruns.count == 1 ? ""
            : reruns.workers == 1 ? ", one at a time" : ", \(reruns.workers) at a time"
        print("🧪 Running every test but the property tests again for \(kills) only properties were recorded "
            + "making\(atATime).")
    }

    /// "🧪 Ran every test but the property tests again for 2 kills: an example failed too for 1, and every test passed
    /// for 1."
    func exampleRerunsFinished(_ tally: ExampleRerunTally) {
        let kills = tally.rerun == 1 ? "1 kill" : "\(tally.rerun) kills"
        var sentence = "🧪 Ran every test but the property tests again for \(kills): an example failed too for "
            + "\(tally.examplesFailed), and every test passed for \(tally.passed)"
        if tally.unsettled > 0 {
            sentence += "; \(tally.unsettled) settled nothing, as they timed out, didn't build, crashed or only failed "
                + "property tests"
        }
        print(sentence + ".")
    }

    /// "⚠️ No kill was tested again with the property tests skipped: …. The reports count what the runs recorded, so
    /// the count by both may be low. Its log is …."
    func exampleRerunsSkipped(reason: String, log: String?) {
        let logSentence = log.map { " Its log is \($0)." } ?? ""
        print(
            "⚠️ No kill was tested again with the property tests skipped: \(reason). The reports count what the runs "
                + "recorded, so the count by both may be low.\(logSentence)"
        )
    }
}
