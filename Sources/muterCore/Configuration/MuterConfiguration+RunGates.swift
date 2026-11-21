extension MuterConfiguration {
    /// The `baseline`, `maxNewSurvivors`, `maxScoreDrop` and `maxDoubtfulKills` keys, those set, as their flags take
    /// them: a path, whole numbers, 0 or more, and points from 0 to 100. Throws on a value of another kind, or a blank
    /// one, so a typo is a configuration error rather than a gate not checked. Whether a count has a baseline file to
    /// compare with is checked once the run's flags are in (`RunGates.overridden(by:in:)`), not here: `--baseline` may
    /// give it.
    static func runGates(in container: KeyedDecodingContainer<CodingKeys>) throws -> RunGates {
        for key in [CodingKeys.maxNewSurvivors, .maxScoreDrop, .maxDoubtfulKills] where container.contains(key) {
            if try container.decodeNil(forKey: key) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue) is blank. Give it a value, or leave it out to check none."
                )
            }
        }
        return RunGates(
            baseline: try text(
                forKey: .baseline,
                naming: "a baseline file's path",
                in: container,
                leftOut: "Leave it out to compare with none."
            ),
            maxNewSurvivors: try whole(forKey: .maxNewSurvivors, in: 0 ... Int.max, in: container),
            maxScoreDrop: try percent(forKey: .maxScoreDrop, in: container, examples: "2 or 0.5"),
            maxDoubtfulKills: try whole(forKey: .maxDoubtfulKills, in: 0 ... Int.max, in: container)
        )
    }

    /// Writes the keys `runGates(in:)` reads, those set: `maxScoreDrop` in plain decimal digits, as `failUnder` is.
    func encodeRunGates(in container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(gates.baseline, forKey: .baseline)
        try container.encodeIfPresent(gates.maxNewSurvivors, forKey: .maxNewSurvivors)
        try container.encodeIfPresent(gates.maxScoreDrop.map(WrittenPercent.init), forKey: .maxScoreDrop)
        try container.encodeIfPresent(gates.maxDoubtfulKills, forKey: .maxDoubtfulKills)
    }
}
