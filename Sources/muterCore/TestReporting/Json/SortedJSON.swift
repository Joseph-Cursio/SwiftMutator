import Foundation

/// JSON for the reports other tools read, Stryker's and SARIF: keys sorted, so a report of one outcome is the same
/// text each time, and slashes unescaped, as paths and URIs are full of them.
enum SortedJSON {
    /// `value` as JSON; "" if it can't be encoded, as for the JSON report.
    static func encoded(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(value) else { return "" }
        return String(lossyUTF8: encoded)
    }
}
