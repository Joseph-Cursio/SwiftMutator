import Foundation

/// The time left, from `Logger.secondsLeft`, for the progress bar or the progress lines.
struct SimpleTimeEstimate: ProgressElementType {
    let firstEstimate: TimeInterval
    let workers: Int
    /// The seconds since the mutants started, or nil before they have.
    let elapsed: () -> TimeInterval?

    func value(_ progressBar: ProgressBar) -> String {
        "ETC: \(timeLeft(tested: progressBar.element, of: progressBar.total))"
    }

    /// The time left with `tested` of `total` mutants tested: "2 h 5 min".
    func timeLeft(tested: Int, of total: Int) -> String {
        let secondsLeft = Logger.secondsLeft(
            tested: tested,
            of: total,
            workers: workers,
            elapsed: elapsed(),
            firstEstimate: firstEstimate
        )
        return Self.text(secondsLeft: secondsLeft)
    }

    /// `seconds` in whole minutes, rounded up so that it never says 0 while any time is left, and in hours from 60
    /// minutes up: "1 min", "59 min", "2 h 5 min". The units are short because this ends the bar's longest line, and
    /// a line that wraps leaves a stale copy behind on every redraw.
    static func text(secondsLeft seconds: TimeInterval) -> String {
        let minutes = max(Int(ceil(seconds / 60)), 0)
        guard minutes >= 60 else {
            return "\(minutes) min"
        }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
