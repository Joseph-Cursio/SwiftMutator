import Foundation
import Rainbow

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
            completedBarElements = Int(progress / Double(progressBar.total))
        }

        let color = colorMap(completedBarElements)
        var barArray = [String](repeating: "-".applyingColor(color), count: completedBarElements)
        barArray += [String](repeating: " ", count: barLength - completedBarElements)
        return "[" + barArray.joined() + "]"
    }
}
