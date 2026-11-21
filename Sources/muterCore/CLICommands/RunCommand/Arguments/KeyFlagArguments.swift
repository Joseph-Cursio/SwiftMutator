import ArgumentParser

/// An argument group with flags for some of the configuration keys `KeyFlags` holds.
protocol KeyFlagArguments {
    /// Sets the values of this group's flags in `flags`.
    func set(in flags: inout KeyFlags)
}

extension KeyFlagArguments {
    /// Refuses `value`, a whole-number flag's, outside `range`, its key's, as the key's decoding does
    /// (`MuterConfiguration.whole(forKey:in:in:)`).
    static func refuse(_ value: Int?, of flag: String, outside range: ClosedRange<Int>) throws {
        guard let value, !range.contains(value) else { return }
        throw ValidationError("\(flag) must be a whole number \(MuterConfiguration.bounds(of: range)), not \(value).")
    }
}

extension KeyFlags {
    /// What the flags of `groups` give, each group's set in turn.
    init(from groups: [any KeyFlagArguments]) {
        self.init()
        for group in groups {
            group.set(in: &self)
        }
    }
}
