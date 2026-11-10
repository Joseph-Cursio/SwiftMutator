/// A flag a results line writes only when it is set: `true`, or no key at all, never `false`. A line read with the key
/// absent, `null` or `false` has it unset.
@propertyWrapper
struct TrueOrAbsent: Codable, Hashable, Sendable {
    var wrappedValue: Bool
}

extension KeyedDecodingContainer {
    /// A `TrueOrAbsent` flag: set if the key holds `true`, unset if it is absent, `null` or `false`.
    func decode( // swiftlint:disable:this unused_declaration - synthesized Codable of a @TrueOrAbsent calls it
        _: TrueOrAbsent.Type,
        forKey key: Key
    ) throws -> TrueOrAbsent {
        try TrueOrAbsent(wrappedValue: decodeIfPresent(Bool.self, forKey: key) ?? false)
    }
}

extension KeyedEncodingContainer {
    /// A `TrueOrAbsent` flag: `true` if it is set, and no key otherwise.
    mutating func encode( // swiftlint:disable:this unused_declaration - synthesized Codable of a @TrueOrAbsent calls it
        _ value: TrueOrAbsent,
        forKey key: Key
    ) throws {
        if value.wrappedValue {
            try encode(true, forKey: key)
        }
    }
}
