import Foundation

extension String {
    func repeated(_ times: Int) -> String { String(repeating: self, count: max(times, 0)) }

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
            .map(\.trimmed)
            // A CRLF is two newlines to `.newlines`, with nothing between them.
            .filter { !$0.isEmpty }
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
