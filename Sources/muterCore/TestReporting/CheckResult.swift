/// How a check the run was asked for came out (`ScoreGate`, `NewSurvivorsCheck`, `ScoreDropCheck`,
/// `DoubtfulKillsCheck`). A summary's `passed` holds it as `true`, `false`, or no key when it wasn't checked.
enum CheckResult: AbsentOrBool {
    case passed
    case failed
    case notChecked

    static var whenTrue: Self { .passed }
    static var whenFalse: Self { .failed }
    static var whenAbsent: Self { .notChecked }

    /// What a run's line, and the Markdown report's paragraph, starts with: ✅ when it passed, ❌ when it failed, ⚠️
    /// when it wasn't checked.
    var mark: String {
        switch self {
        case .passed: "✅"
        case .failed: "❌"
        case .notChecked: "⚠️"
        }
    }
}
