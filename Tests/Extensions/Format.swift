import SwiftFormat

/// Formats Swift source with swift-format's default configuration, or returns "" if it can't be formatted.
public func formatCode(_ code: String) -> String {
    let formatter = SwiftFormatter(configuration: Configuration())
    var stream = FormatterOutputStream()

    try? formatter.format(source: code, assumingFileURL: nil, selection: .infinite, to: &stream)

    return stream.output
}
