/// the progress bar element e.g. "[----------------------        ]"
struct ProgressBarLine: ProgressElementType {
    let barLength: Int

    init(barLength: Int = 30) {
        self.barLength = barLength
    }

    func value(_ progressBar: ProgressBar) -> String {
        var completedBarElements = 0
        if progressBar.isEmpty {
            completedBarElements = barLength
        } else {
            completedBarElements = Int(Double(barLength) * (Double(progressBar.element) / Double(progressBar.total)))
        }

        var barArray = [String](repeating: "-", count: completedBarElements)
        barArray += [String](repeating: " ", count: barLength - completedBarElements)
        return "[" + barArray.joined() + "]"
    }
}
