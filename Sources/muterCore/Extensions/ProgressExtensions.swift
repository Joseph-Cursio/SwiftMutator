import Foundation
import Rainbow

class SimpleTimeEstimate: ProgressElementType {
    private let initialEstimate: TimeInterval
    private var lastTime: Date = .init()

    init(initialEstimate: TimeInterval) {
        self.initialEstimate = initialEstimate
    }

    func value(_ progressBar: ProgressBar) -> String {
        let timeSinceLastInvocation = Date()
        let timePerItem = DateInterval(start: lastTime, end: timeSinceLastInvocation).duration

        let estimatedTimeRemaining = progressBar.element == 0 ?
            initialEstimate :
            Double(progressBar.count - progressBar.element) * timePerItem

        lastTime = Date()

        return "ETC: \(Self.text(secondsLeft: estimatedTimeRemaining))"
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

struct ProgressOneIndexed: ProgressElementType {
    init() {}

    func value(_ progressBar: ProgressBar) -> String {
        let index = progressBar.element + 1 > progressBar.count ?
            progressBar.element :
            progressBar.element + 1
        return "\(index) of \(progressBar.count)"
    }
}

struct ColoredProgressBarLine: ProgressElementType {
    let barLength: Int

    private func colorMap(_ completedBarElements: Int) -> Color {
        let interval = barLength / 4
        switch completedBarElements {
        case 0 ... interval: return Color.magenta
        case (interval + 1) ... (2 * interval): return Color.lightRed
        case (2 * interval + 1) ... (3 * interval): return Color.yellow
        default: return Color.green
        }
    }

    init(barLength: Int = 30) {
        self.barLength = barLength
    }

    func value(_ progressBar: ProgressBar) -> String {
        var completedBarElements = 0
        if progressBar.isEmpty {
            completedBarElements = barLength
        } else {
            let progress = Double(barLength) * Double(progressBar.element)
            completedBarElements = Int(progress / Double(progressBar.count))
        }

        let color = colorMap(completedBarElements)
        var barArray = [String](repeating: "-".applyingColor(color), count: completedBarElements)
        barArray += [String](repeating: " ", count: barLength - completedBarElements)
        return "[" + barArray.joined(separator: "") + "]"
    }
}
struct ProgressBarMultilineTerminalPrinter: ProgressBarPrinter {
    /// When the bar was last drawn, by the injected clock.
    private var lastPrinted: DispatchTime?
    private let numberOfLines: Int
    @Dependency(\.logger)
    private var logger: Logger
    @Dependency(\.instant)
    private var instant: Instant

    init(numberOfLines: Int) {
        self.numberOfLines = numberOfLines
        // the cursor is moved up before printing the progress bar.
        // have to move the cursor down one line initially.
        logger.print("")
    }

    /// Draws the bar at most every tenth of a second, so a burst of finished mutants redraws it once, but always its
    /// last state.
    mutating func display(_ progressBar: ProgressBar) {
        let now = instant()
        if let lastPrinted,
           now.uptimeNanoseconds < lastPrinted.uptimeNanoseconds + 100_000_000,
           progressBar.element != progressBar.count {
            return
        }
        let lines = "\u{1B}[1A\u{1B}".repeated(numberOfLines)
        logger.print("\(lines)[K\(progressBar.value)")
        lastPrinted = now
    }
}
