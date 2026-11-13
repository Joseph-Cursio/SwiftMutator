/// Collects swift-format's output into a string.
final class FormatterOutputStream: TextOutputStream {
    private(set) var output: String = ""

    func write(_ string: String) {
        output += string
    }
}
