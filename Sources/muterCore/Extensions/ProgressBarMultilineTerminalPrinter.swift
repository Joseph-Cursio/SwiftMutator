import Dispatch

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
           progressBar.element != progressBar.total {
            return
        }
        // Up a line and erase it, for each line of the bar, so a shorter line leaves nothing of the one it replaces.
        let erase = "\u{1B}[1A\u{1B}[2K".repeated(numberOfLines)
        logger.print(erase + progressBar.value)
        lastPrinted = now
    }
}
