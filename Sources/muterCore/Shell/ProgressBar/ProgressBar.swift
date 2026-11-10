protocol ProgressBarPrinter {
    mutating func display(_ progressBar: ProgressBar)
}

struct ProgressBarTerminalPrinter: ProgressBarPrinter {
    var lastPrintedTime = 0.0

    init() {
        // the cursor is moved up before printing the progress bar.
        // have to move the cursor down one line initially.
        print("")
    }

    mutating func display(_ progressBar: ProgressBar) {
        let currentTime = ProgressBar.timeOfDay()
        if currentTime - lastPrintedTime > 0.1 || progressBar.element == progressBar.total {
            print("\u{1B}[1A\u{1B}[K\(progressBar.value)")
            lastPrintedTime = currentTime
        }
    }
}

// MARK: - ProgressBar

struct ProgressBar {
    var isEmpty: Bool { total <= 0 }
    /// How many items are done. `next()` draws it, then counts one more.
    private(set) var element = 0
    let startTime = Self.timeOfDay()

    let total: Int
    let configuration: [ProgressElementType]?

    static var defaultConfiguration: [ProgressElementType] {
        [
            ProgressIndex(),
            ProgressBarLine(),
            ProgressTimeEstimates(),
        ]
    }

    var printer: ProgressBarPrinter

    var value: String {
        let resolvedConfiguration = configuration ?? Self.defaultConfiguration
        let values = resolvedConfiguration.map { $0.value(self) }
        return values.joined(separator: " ")
    }

    init(count: Int, configuration: [ProgressElementType]? = nil, printer: ProgressBarPrinter? = nil) {
        total = count
        self.configuration = configuration
        self.printer = printer ?? ProgressBarTerminalPrinter()
    }

    mutating func next() {
        guard element <= total else {
            return
        }
        let anotherSelf = self
        printer.display(anotherSelf)
        element += 1
    }
}
