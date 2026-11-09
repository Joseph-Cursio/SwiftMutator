import Foundation
import Yams

/// A key of a configuration file that isn't one of `MuterConfiguration.CodingKeys`, which decoding ignores, and the
/// known key it is most likely a misspelling of, if any. A misspelled `mutationTestTimeout` would otherwise leave the
/// run on its default limit without a word (#122).
struct UnknownConfigurationKey: Equatable, Sendable {
    let key: String
    /// The known key `key` is closest to, if it is close enough to be meant: see `closest(to:)`.
    let closest: String?

    /// The keys of `data`'s top-level mapping, YAML or JSON, that no configuration key is, in the order they are
    /// written, once each; none if it isn't a mapping, which decoding refuses. A YAML merge key, `<<`, isn't one: the
    /// keys of the mappings it merges are checked in its place, as decoding reads them.
    static func found(in data: Data) -> [UnknownConfigurationKey] {
        guard let text = String(data: data, encoding: .utf8),
              let mapping = (try? Yams.compose(yaml: text))?.mapping
        else {
            return []
        }
        let known = Set(MuterConfiguration.CodingKeys.allCases.map(\.stringValue))
        var seen: Set<String> = []
        return keys(of: mapping)
            .filter { !known.contains($0) && seen.insert($0).inserted }
            .map { UnknownConfigurationKey(key: $0, closest: closest(to: $0)) }
    }

    /// `mapping`'s keys, with those of the mappings a merge key merges in its place.
    private static func keys(of mapping: Node.Mapping) -> [String] {
        mapping.flatMap { key, value -> [String] in
            guard key.string == "<<" else { return key.string.map { [$0] } ?? [] }
            let merged = value.mapping.map { [$0] } ?? (value.sequence?.compactMap(\.mapping) ?? [])
            return merged.flatMap(keys(of:))
        }
    }

    /// Names a key is likely written as that are not close to it by their letters, each with its key: a run flag's
    /// name, or another name for what the key holds.
    private static let otherNames = [
        "timeout": "mutationTestTimeout",
        "workers": "mutationTestWorkers",
        "excludefiles": "exclude",
        "excludepaths": "exclude",
        "excludelist": "exclude",
        "excludefilelist": "exclude",
        "excludefunctions": "excludeCalls",
        "excludemethods": "excludeCalls",
        "excludecalllist": "excludeCalls",
        "report": "reports",
    ]

    /// The known key `key` is meant as, or nil when none is close enough or two are as close. Keys are compared by
    /// letters and digits alone, in any case, so `mutationTestTimeOut` and `fail-under`, as the flag is written, find
    /// theirs. Another name a key is often written as wins (`otherNames`). Then the closest by edit distance, within a
    /// few edits for its length, and within about half the letters where the two differ, so `excludeFiles` isn't taken
    /// for `excludeCalls`. Failing that, the one key that ends with `key`, or that `key` ends with, as a key's last
    /// word says what it holds; and failing that, the one that starts so, as `coverage` starts `coverageThreshold`.
    static func closest(to key: String) -> String? {
        let written = normalized(key)
        guard !written.isEmpty else { return nil }
        if let named = otherNames[written] {
            return named
        }
        let known = MuterConfiguration.CodingKeys.allCases
            .map { (key: $0.stringValue, normalized: normalized($0.stringValue)) }
        let allowed = written.count <= 4 ? 1 : written.count <= 8 ? 2 : 3
        let near = known
            .map { known in
                (
                    key: known.key,
                    distance: editDistance(written, known.normalized),
                    differing: differing(written, known.normalized)
                )
            }
            .filter { $0.distance <= allowed && $0.distance <= max(1, ($0.differing + 1) / 2) }
        if let nearest = near.map(\.distance).min() {
            let tied = near.filter { $0.distance == nearest }
            return tied.count == 1 ? tied[0].key : nil
        }
        guard written.count >= 4 else { return nil }
        let ends: (String) -> Bool = { $0.hasSuffix(written) || written.hasSuffix($0) }
        let starts: (String) -> Bool = { $0.hasPrefix(written) || written.hasPrefix($0) }
        for matches in [ends, starts] {
            let found = known.filter { $0.normalized.count >= 4 && matches($0.normalized) }
            if !found.isEmpty {
                return found.count == 1 ? found[0].key : nil
            }
        }
        return nil
    }

    private static func normalized(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// How many characters `first` and `second` differ in where they differ: the longer of what is left of each once
    /// the start and the end they share are taken off.
    private static func differing(_ first: String, _ second: String) -> Int {
        let start = zip(first, second).prefix { $0 == $1 }.count
        let first = first.dropFirst(start), second = second.dropFirst(start)
        let end = zip(first.reversed(), second.reversed()).prefix { $0 == $1 }.count
        return max(first.count, second.count) - end
    }

    /// The fewest insertions, deletions and substitutions of a character, and swaps of two side by side, that turn
    /// `first` into `second`, each character edited once at most: `excldue` is one swap from `exclude`.
    private static func editDistance(_ first: String, _ second: String) -> Int {
        let first = Array(first), second = Array(second)
        guard !first.isEmpty, !second.isEmpty else { return max(first.count, second.count) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: second.count + 1), count: first.count + 1)
        for row in 0 ... first.count { table[row][0] = row }
        for column in 0 ... second.count { table[0][column] = column }
        for row in 1 ... first.count {
            for column in 1 ... second.count {
                let cost = first[row - 1] == second[column - 1] ? 0 : 1
                var best = min(
                    table[row - 1][column] + 1,
                    table[row][column - 1] + 1,
                    table[row - 1][column - 1] + cost
                )
                if row > 1, column > 1, first[row - 1] == second[column - 2], first[row - 2] == second[column - 1] {
                    best = min(best, table[row - 2][column - 2] + 1)
                }
                table[row][column] = best
            }
        }
        return table[first.count][second.count]
    }
}
