import Foundation

extension String {
    func repeated(_ times: Int) -> String { (0 ..< times).reduce("") { current, _ in current + "\(self)" } }

    func removingSubrange(_ bounds: Range<String.Index>?) -> String {
        guard let bounds else {
            return self
        }
        var result = self
        result.removeSubrange(bounds)
        return result
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var inlined: String {
        components(separatedBy: .newlines)
            .map { $0.trimmed }
            .joined(separator: " ")
    }

    func distance(to index: Index) -> Int {
        distance(from: startIndex, to: index)
    }

    var nilIfEmpty: String? {
        !isEmpty ? self : nil
    }

    /// FNV-1a of the UTF-8 bytes, in hex: unlike `hashValue`, the same in every process and on every machine.
    var stableHash: String {
        let hash = utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
        return String(hash, radix: 16)
    }
}

extension String {
    /// In UTF-16 units, as NSRegularExpression counts. `count` counts Characters, so any one that takes more than one
    /// unit, such as an emoji, a decomposed accent or a CRLF line ending, would cut the end of the text off the search.
    private var stringRange: NSRange { NSRange(startIndex..., in: self) }

    func stringsMatchingRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        NSRegularExpression
            .regexWithPattern(pattern, options)
            .matches(
                in: self,
                options: [],
                range: stringRange
            )
            .map { String(substring(with: $0.range)) }
    }

    func matches(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        !NSRegularExpression
            .regexWithPattern(pattern, options)
            .matches(
                in: self,
                options: [],
                range: stringRange
            ).isEmpty
    }

    /// The whole of the first match, capture groups included. `firstCaptureOf` gives a group's text alone.
    func firstMatchOf(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        NSRegularExpression
            .regexWithPattern(pattern, options)
            .firstMatch(
                in: self,
                options: [],
                range: stringRange
            )
            .map { String(substring(with: $0.range)) }
    }

    /// The text of `pattern`'s first capture group in the first match, or nil if nothing matches, the pattern has no
    /// group, or the group takes no part in the match.
    func firstCaptureOf(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        NSRegularExpression
            .regexWithPattern(pattern, options)
            .firstMatch(
                in: self,
                options: [],
                range: stringRange
            )
            // `range(at:)` raises for a group the pattern doesn't have.
            .flatMap { $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: self) : nil }
            .map { String(self[$0]) }
    }

    private func substring(with nsrange: NSRange) -> String {
        guard let range = Range(nsrange, in: self) else {
            return self
        }
        return String(self[range])
    }
}
