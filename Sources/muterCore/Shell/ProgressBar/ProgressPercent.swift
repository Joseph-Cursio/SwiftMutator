/// the percentage element e.g. "90.0%"
struct ProgressPercent: ProgressElementType {
    let decimalPlaces: Int

    init(decimalPlaces: Int = 0) {
        self.decimalPlaces = decimalPlaces
    }

    func value(_ progressBar: ProgressBar) -> String {
        var percentDone = 100.0
        if !progressBar.isEmpty {
            percentDone = Double(progressBar.element) / Double(progressBar.total) * 100
        }
        return "\(percentDone.format(decimalPlaces))%"
    }
}
