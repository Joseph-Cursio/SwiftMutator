import SwiftFormat

/// `code` as swift-format lays it out, so a snapshot of generated code reads like code.
public func formatCode(_ code: String) -> String {
    let formatter = SwiftFormatter(configuration: Configuration())
    var stream = OutputStream()

    try? formatter.format(source: code, assumingFileURL: nil, selection: .infinite, to: &stream)

    return stream.output
}

private class OutputStream: TextOutputStream {
    private(set) var output: String = ""

    func write(_ string: String) {
        output += string
    }
}
