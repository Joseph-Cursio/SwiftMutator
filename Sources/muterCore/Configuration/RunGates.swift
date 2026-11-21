/// What a finished run is judged by besides `failUnder`: its survivors and its score against a committed baseline
/// file, and its doubtful kills. Given by the `baseline`, `maxNewSurvivors`, `maxScoreDrop` and `maxDoubtfulKills`
/// keys, or by the `--baseline`, `--max-new-survivors`, `--max-score-drop` and `--max-doubtful-kills` flags of `run`
/// and `run-without-mutating`, each of which replaces its key (`overridden(by:in:)`). `report` takes only the flags.
struct RunGates: Equatable, Sendable {
    /// The baseline file whose survivors a finished run's are compared with (`NewSurvivorsCheck`), and whose score
    /// with `maxScoreDrop` (`ScoreDropCheck`). A key's path is relative to the project's folder; once the run's flags
    /// are in, it is absolute.
    var baseline: String?
    /// How many new survivors the comparison with `baseline`'s file lets pass. Once the run's flags are in, 0 with a
    /// baseline file and no count, and nil without one.
    var maxNewSurvivors: Int?
    /// How many points a finished whole run's score may fall below `baseline`'s file's; nil checks none.
    var maxScoreDrop: Double?
    /// How many kills a finished run's evidence may leave in doubt (`DoubtfulKillsCheck`); nil checks none.
    var maxDoubtfulKills: Int?

    init(
        baseline: String? = nil,
        maxNewSurvivors: Int? = nil,
        maxScoreDrop: Double? = nil,
        maxDoubtfulKills: Int? = nil
    ) {
        self.baseline = baseline
        self.maxNewSurvivors = maxNewSurvivors
        self.maxScoreDrop = maxScoreDrop
        self.maxDoubtfulKills = maxDoubtfulKills
    }

    /// These keys with each of `flags`' values in place of its own, a key's `baseline` resolved against `folder`, the
    /// project's (a flag's is absolute already), and `maxNewSurvivors` 0 when there is a baseline file and neither
    /// gives a count. Refused when `maxNewSurvivors` or `maxScoreDrop` is given and neither gives a baseline file.
    /// A run whose `--write-baseline` file, `writing`, is the key's own, with no `--baseline`, sets the key's file and
    /// its counts aside: it is the run that makes that file, which may be missing or of another scope until it does.
    func overridden(by flags: Self, in folder: String, writing: String? = nil) throws -> Self {
        let keyFile = baseline.map { Self.resolved($0, in: folder) }
        let setAside = flags.baseline == nil && Self.samePath(keyFile, writing)
        let keys = setAside ? Self(maxDoubtfulKills: maxDoubtfulKills) : self
        let file = flags.baseline ?? (setAside ? nil : keyFile)
        guard file != nil else {
            if let refusal = Self.refusal(keys: keys, flags: flags) {
                throw MuterError.configurationParsingError(reason: refusal)
            }
            return Self(maxDoubtfulKills: flags.maxDoubtfulKills ?? maxDoubtfulKills)
        }
        return Self(
            baseline: file,
            maxNewSurvivors: flags.maxNewSurvivors ?? keys.maxNewSurvivors ?? 0,
            maxScoreDrop: flags.maxScoreDrop ?? keys.maxScoreDrop,
            maxDoubtfulKills: flags.maxDoubtfulKills ?? maxDoubtfulKills
        )
    }

    /// Why a run with neither `--baseline` nor `baseline:` can't take a count that only compares with a baseline file:
    /// the first given of `--max-new-survivors`, `--max-score-drop`, `maxNewSurvivors:` and `maxScoreDrop:`.
    private static func refusal(keys: Self, flags: Self) -> String? {
        let given: [(String, Bool)] = [
            ("--max-new-survivors", flags.maxNewSurvivors != nil),
            ("--max-score-drop", flags.maxScoreDrop != nil),
            ("`maxNewSurvivors:`", keys.maxNewSurvivors != nil),
            ("`maxScoreDrop:`", keys.maxScoreDrop != nil),
        ]
        return given.first(where: \.1).map { "\($0.0) only applies with `baseline:` or --baseline." }
    }

    /// Whether `one` and `other` name one file, as `/a/./b.yml` and `/a/b.yml` do; false when either is nil.
    private static func samePath(_ one: String?, _ other: String?) -> Bool {
        guard let one, let other else { return false }
        return one.standardizingPath == other.standardizingPath
    }

    /// `path` resolved against `folder`, as `reports:`' paths are: an absolute one is kept, and a leading `~` is the
    /// home folder, which YAML never expands.
    private static func resolved(_ path: String, in folder: String) -> String {
        let expanded = path.expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : folder.appendingPathComponent(path)
    }
}
