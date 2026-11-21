/// Why the baseline file, `--baseline`'s or `baseline:`'s, can't be compared with: it can't be read, or it records a
/// run of another scope, whose mutants differ. Every reason found, in one message, printed as it is
/// (`RunCommand.message(showing:)`). A run exits 8 (`ExitCode.baselineRefused`), before any mutant is tested, and
/// `report` too, before any report is made.
struct BaselineRefused: Error, Equatable, CustomStringConvertible {
    /// The reason for a path with no file, which says how to make one.
    static let noFile = "There is no baseline file there. Write one with --write-baseline."

    /// The baseline file, as given, made absolute.
    let path: String
    let reasons: [String]
    /// What would let it through, said once after the reasons; nil when each says it.
    var advice: String?
    /// Whether the configuration's `baseline:` named the file, not `--baseline`.
    var namedByKey = false

    var description: String {
        let file = Logger.shellQuoted(path) + (namedByKey ? ", which the configuration's baseline: names" : "")
        var lines = ["SwiftMutator won't compare the survivors with the baseline file \(file):"]
        lines += reasons.map { "  - " + $0 }
        if let advice {
            lines.append(advice)
        }
        return lines.joined(separator: "\n")
    }

    /// This refusal of the file the configuration's `baseline:` names. Every run that tests reads it first but one
    /// whose `--write-baseline` names it, which sets the key aside (`RunGates.overridden(by:in:writing:)`), so the
    /// advice says that run writes it.
    func namedByTheKey() -> Self {
        let keyAdvice = "A run whose --write-baseline names this file sets baseline: aside, and writes it."
        return Self(
            path: path,
            reasons: reasons.map { $0 == Self.noFile ? "There is no baseline file there." : $0 },
            advice: advice.map { $0 + " " + keyAdvice } ?? keyAdvice,
            namedByKey: true
        )
    }

    /// Refuses `current`, a run's scope or the results' that `report` reads, for `baseline`'s, when they differ:
    /// `subject` names `current`, "this run" or "these results". Nothing when they're the same.
    static func check(_ current: BaselineScope, against baseline: BaselineFile, subject: String) throws {
        let differences = current.differences(from: baseline.scope)
        guard !differences.isEmpty else { return }
        throw Self(
            path: baseline.path,
            reasons: differences.map { difference in
                "\(difference.name) is \(difference.was ?? "not set") in the baseline file, and "
                    + "\(difference.isNow ?? "not set") in \(subject)."
            },
            advice: "Its survivors are another scope's mutants, so none can be compared. Run as the baseline file's "
                + "run did, or write a new baseline file with --write-baseline from a run of this scope."
        )
    }
}
