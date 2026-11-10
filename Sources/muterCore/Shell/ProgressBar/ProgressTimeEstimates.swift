/// the time estimates e.g. "ETA: 00:00:02 (at 1.00 it/s)"
struct ProgressTimeEstimates: ProgressElementType {
    func value(_ progressBar: ProgressBar) -> String {
        let totalTime = ProgressBar.timeOfDay() - progressBar.startTime

        var itemsPerSecond = 0.0
        var estimatedTimeRemaining = 0.0
        if progressBar.element > 0 {
            itemsPerSecond = Double(progressBar.element) / totalTime
            estimatedTimeRemaining = Double(progressBar.total - progressBar.element) / itemsPerSecond
        }

        let estimatedTimeRemainingString = formatDuration(estimatedTimeRemaining)

        return "ETA: \(estimatedTimeRemainingString) (at \(itemsPerSecond.format(2))) it/s)"
    }

    private func formatDuration(_ duration: Double) -> String {
        let wholeSeconds = Int(duration)
        let seconds = Double(wholeSeconds % 60)
        let minutes = Double((wholeSeconds / 60) % 60)
        let hours = Double(wholeSeconds / 3_600)
        return "\(hours.format(0, minimumIntegerPartLength: 2)):"
            + "\(minutes.format(0, minimumIntegerPartLength: 2)):"
            + "\(seconds.format(0, minimumIntegerPartLength: 2))"
    }
}
