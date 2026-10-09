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

        let remainingMinutes = Int(ceil(estimatedTimeRemaining / 60))

        let formattedRemainingMinutes = "\(remainingMinutes) \(remainingMinutes == 1 ? "minutes" : "minute")"

        return "ETC: \(formattedRemainingMinutes)"
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
