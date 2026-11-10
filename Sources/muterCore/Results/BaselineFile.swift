import Foundation
import Rainbow
import Yams

/// A run's survivors, which `--write-baseline` saves and `--baseline` compares a later run's with
/// (`NewSurvivorsCheck`), so a pull request's job fails on a survivor it adds and not on those the project already
/// had. Meant to be committed as `muter.baseline.yml` at the project's root, which `ProjectTree` leaves out, as it does
/// `muter.triage.yml`, so committing a new one refuses no `--resume` and tests nothing again in a `--reuse`.
///
/// Only a whole run's results make one: one that leaves some mutants out would record their survivors as gone. It
/// records the score's counts too, as `ScoreGate` takes them, and what a later run must share for its mutants to be
/// comparable (`BaselineScope`). Saved sorted, so a commit's diff shows only what changed; read strictly, as a file a
/// person may edit by hand, so a misspelled key isn't taken for an absent one.
struct BaselineFile: Equatable {
    /// The name the README recommends, at the project's root.
    static let fileName = "muter.baseline.yml"
    /// Raised when a key is taken out or changes its meaning. A file of a newer format is refused, as its keys may
    /// mean what this SwiftMutator can't tell.
    static let formatVersion = 1
    /// The comment a saved file starts with, which loading it drops.
    static let introduction = "# Written by swift-mutator --write-baseline. Commit it, and compare runs with it with "
        + "--baseline."

    /// The score's counts, as `ScoreGate` takes them: the mutants killed, and those scored, including any taken out
    /// of the build with others, which count as not killed.
    struct Score: Codable, Equatable {
        let killed: Int
        let scored: Int
    }

    /// Where it was read from, or is saved to, as given.
    let path: String
    let formatVersion: Int
    /// The SwiftMutator version that tested the run, as its results header records it.
    let swiftMutator: String
    let score: Score
    let scope: BaselineScope
    let survivors: [BaselineSurvivor]

    init(
        path: String,
        formatVersion: Int = Self.formatVersion,
        swiftMutator: String,
        score: Score,
        scope: BaselineScope,
        survivors: [BaselineSurvivor]
    ) {
        self.path = path
        self.formatVersion = formatVersion
        self.swiftMutator = swiftMutator
        self.score = score
        self.scope = scope
        self.survivors = survivors
    }
}

/// One mutant a baseline file records as surviving: one the tests didn't kill, as it survived, timed out, or no test
/// ran its code. A key holds its mutant's line and column, which any edit above it moves, so an entry also holds what
/// its mutant changes, and its line (`BaselineMatches`).
struct BaselineSurvivor: Equatable {
    /// How it survived, which matching ignores: a timeout and a survivor flip between runs (#89), and both count
    /// against the score.
    enum Outcome: String, Codable, CaseIterable {
        case survived
        case timedOut
        case notCovered

        /// The outcome of a mutant with `outcome`, when the tests didn't kill it; nil otherwise. A mutant not covered
        /// is one whose block no test ran, never a file's row for having no coverage, which has no key.
        init?(_ outcome: TestSuiteOutcome) {
            switch outcome {
            case .passed: self = .survived
            case .timeout: self = .timedOut
            case .noCoverage: self = .notCovered
            default: return nil
            }
        }
    }

    let mutant: MutantKey
    let outcome: Outcome
    /// The mutant's snapshot: what it replaces, and what with.
    let before: String
    let after: String
    /// The line it changes, without the spaces around it (`AppliedMutationOperator.changedLine`); nil when its change
    /// spans lines, or its file had changed since it was tested, or couldn't be read.
    let line: String?

    init(mutant: MutantKey, outcome: Outcome, before: String, after: String, line: String? = nil) {
        self.mutant = mutant
        self.outcome = outcome
        self.before = before
        self.after = after
        self.line = line?.trimmingCharacters(in: .whitespaces)
    }
}

/// What a baseline file records of the run it was written from, and `--baseline` compares with the run that checks it:
/// the operators, `skipCoverage`, and the configuration keys a resume compares (`ResumeCheck`), but for `executable`,
/// an absolute path that differs between machines. Two runs that differ in any of these discover different mutants, or
/// judge them differently, so their survivors can't be compared. Not what `--since`, `--shard`, `--sample` or
/// `--files-to-mutate` choose: a run limited so is compared only on the mutants it tested.
struct BaselineScope: Equatable {
    /// The operators by name, sorted, once each.
    let operators: [String]
    let skipCoverage: Bool
    let configuration: Configuration

    /// The configuration keys compared, under their own names.
    struct Configuration: Codable, Equatable {
        let arguments: [String]
        /// `buildSystem:` as written; nil when it isn't set.
        let buildSystem: String?
        let coverageThreshold: Double
        /// Sorted, once each, as `--exclude`'s entries come after the file's.
        let exclude: [String]
        let excludeCalls: [String]
        /// nil when it isn't set: the default comes from the baseline run's time.
        let mutationTestTimeout: Double?

        init(
            arguments: [String] = [],
            buildSystem: String? = nil,
            coverageThreshold: Double = 0,
            exclude: [String] = [],
            excludeCalls: [String] = [],
            mutationTestTimeout: Double? = nil
        ) {
            self.arguments = arguments
            self.buildSystem = buildSystem
            self.coverageThreshold = coverageThreshold
            self.exclude = Set(exclude).sorted()
            self.excludeCalls = excludeCalls
            self.mutationTestTimeout = mutationTestTimeout
        }

        /// `configuration`'s keys that are compared, after the flags that override them.
        init(_ configuration: MuterConfiguration) {
            self.init(
                arguments: configuration.testCommandArguments,
                buildSystem: configuration.explicitBuildSystem?.rawValue,
                coverageThreshold: configuration.coverageThreshold,
                exclude: configuration.excludeFileList,
                excludeCalls: configuration.excludeCallList,
                mutationTestTimeout: configuration.testSuiteTimeout
            )
        }

        /// A configuration with these keys, and every other as no file sets it, which `ResumeCheck` compares.
        var asMuterConfiguration: MuterConfiguration {
            MuterConfiguration(
                arguments: arguments,
                excludeList: exclude,
                excludeCallList: excludeCalls,
                coverageThreshold: coverageThreshold,
                testSuiteTimeOut: mutationTestTimeout,
                // Never `unknown`, which an earlier version wrote for any value but these, and then ignored.
                buildSystem: buildSystem.flatMap(BuildSystem.init(written:))
            )
        }
    }

    init(operators: [String], skipCoverage: Bool, configuration: Configuration) {
        self.operators = Set(operators).sorted()
        self.skipCoverage = skipCoverage
        self.configuration = configuration
    }

    /// What a run with `configuration`, after its flags, `operators` and `skipCoverage` records.
    init(configuration: MuterConfiguration, operators: [MutationOperator.Id], skipCoverage: Bool) {
        self.init(
            operators: operators.map(\.rawValue),
            skipCoverage: skipCoverage,
            configuration: Configuration(configuration)
        )
    }

    /// What `header`'s session recorded.
    init(header: ResultsHeader) {
        self.init(
            operators: header.operators,
            skipCoverage: header.skipCoverage,
            configuration: Configuration(header.configuration)
        )
    }

    /// How this scope differs from the `recorded` one, a baseline file's, by name: the operators, `skipCoverage`, then
    /// each configuration key that differs, by name, as a resume says them (`ResumeCheck.configurationDifferences`).
    /// Empty when they're the same.
    func differences(from recorded: Self) -> [ResumeCheck.Difference] {
        var differences: [ResumeCheck.Difference] = []
        if operators != recorded.operators {
            differences.append(
                .init(name: "operators", was: Self.json(recorded.operators), isNow: Self.json(operators))
            )
        }
        if skipCoverage != recorded.skipCoverage {
            differences.append(
                .init(name: "skipCoverage", was: "\(recorded.skipCoverage)", isNow: "\(skipCoverage)")
            )
        }
        return differences + ResumeCheck.configurationDifferences(
            recorded.configuration.asMuterConfiguration,
            configuration.asMuterConfiguration
        )
    }

    /// `values` as JSON on one line: `["RelationalBoundary","SwapTernary"]`.
    private static func json(_ values: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]))
            .map { String(lossyUTF8: $0) } ?? "\(values)"
    }
}

extension BaselineFile {
    /// The baseline file of `outcome`'s survivors, to save at `path`, whose scope is `scope`, tested by SwiftMutator
    /// `version`: every mutant it tested that the tests didn't kill, with its line from its original file while that
    /// is as it was tested (`ReportSources`), read by `readSource`.
    init(
        of outcome: MutationTestOutcome,
        scope: BaselineScope,
        version: String,
        path: String,
        readingSourcesWith readSource: @escaping ReadFile = dependency(\.readSourceFile)
    ) {
        let gate = ScoreGate(failUnder: 0, judging: outcome)
        let survivors = BaselineMatches.TestedMutant.all(of: outcome, readingSourcesWith: readSource)
            .compactMap { mutant -> BaselineSurvivor? in
                guard case let .survivor(how) = mutant.kind else { return nil }
                return BaselineSurvivor(
                    mutant: mutant.key,
                    outcome: how,
                    before: mutant.before,
                    after: mutant.after,
                    line: mutant.line
                )
            }
        self.init(
            path: path,
            swiftMutator: version,
            score: Score(killed: gate.killed, scored: gate.scored),
            scope: scope,
            survivors: survivors
        )
    }
}

// MARK: - Saving

extension BaselineFile {
    private struct Saved: Encodable {
        let formatVersion: Int
        let swiftMutator: String
        let score: Score
        let scope: SavedScope
        let survivors: [SavedSurvivor]
    }

    private struct SavedScope: Encodable {
        let operators: [String]
        let skipCoverage: Bool
        let configuration: SavedConfiguration
    }

    private struct SavedConfiguration: Encodable {
        let arguments: [String]
        let buildSystem: String?
        let coverageThreshold: WrittenNumber
        let exclude: [String]
        let excludeCalls: [String]
        let mutationTestTimeout: WrittenNumber?
    }

    private struct SavedSurvivor: Encodable {
        let mutant: String
        let outcome: String
        let before: String
        let after: String
        let line: String?
    }

    /// A number as YAML writes it in plain digits, as a person would (`ScoreGate.shown`): 60, 72.5; never 6e+1.
    private struct WrittenNumber: Encodable, YAMLEncodable {
        let value: Double

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Decimal(string: ScoreGate.shown(value)) ?? Decimal(value))
        }

        func box() -> Node {
            Node(ScoreGate.shown(value), Tag(value == value.rounded() ? .int : .float))
        }
    }

    /// Its survivors by path, line, column, operator and repeat, so a commit's diff shows only what changed.
    var sortedSurvivors: [BaselineSurvivor] {
        survivors.sorted { $0.mutant.comesBefore($1.mutant) }
    }

    /// The file as YAML, after `introduction`: the keys in the order a reader wants them, the survivors sorted.
    func yaml() throws -> String {
        let configuration = scope.configuration
        let saved = Saved(
            formatVersion: formatVersion,
            swiftMutator: swiftMutator,
            score: score,
            scope: .init(
                operators: scope.operators,
                skipCoverage: scope.skipCoverage,
                configuration: .init(
                    arguments: configuration.arguments,
                    buildSystem: configuration.buildSystem,
                    coverageThreshold: WrittenNumber(value: configuration.coverageThreshold),
                    exclude: configuration.exclude,
                    excludeCalls: configuration.excludeCalls,
                    mutationTestTimeout: configuration.mutationTestTimeout.map(WrittenNumber.init)
                )
            ),
            survivors: sortedSurvivors.map {
                .init(
                    mutant: $0.mutant.description,
                    outcome: $0.outcome.rawValue,
                    before: $0.before,
                    after: $0.after,
                    line: $0.line
                )
            }
        )
        // Each value on one line, however long, so that a changed line of code changes one line of the file's diff.
        let encoder = YAMLEncoder()
        encoder.options.width = -1
        return Self.introduction + "\n" + (try encoder.encode(saved))
    }

    /// Saves it at `path`, `~` expanded, making any folder on the way that isn't there, as a report is saved
    /// (`ReportWriter.save`); says whether it was saved.
    func save(using fileManager: FileSystemManager) -> Bool {
        guard let text = try? yaml() else { return false }
        return ReportWriter.save(text, to: URL.expandingTilde(path), using: fileManager)
    }
}

// MARK: - Loading

extension BaselineFile {
    /// The keys of each mapping in the file, in the order they're saved.
    private static let topKeys = ["formatVersion", "swiftMutator", "score", "scope", "survivors"]
    private static let scoreKeys = ["killed", "scored"]
    private static let scopeKeys = ["operators", "skipCoverage", "configuration"]
    private static let configurationKeys = [
        "arguments", "buildSystem", "coverageThreshold", "exclude", "excludeCalls", "mutationTestTimeout",
    ]
    private static let survivorKeys = ["mutant", "outcome", "before", "after", "line"]

    /// The file as YAML gives it. A mutant and an outcome are checked once it's decoded: a decoder's errors say where,
    /// in its own words, and hide why.
    private struct Written: Decodable {
        struct Scope: Decodable {
            let operators: [String]
            let skipCoverage: Bool
            let configuration: BaselineScope.Configuration
        }

        struct Survivor: Decodable {
            let mutant: String
            let outcome: String
            let before: String
            let after: String
            let line: String?
        }

        let formatVersion: Int
        let swiftMutator: String
        let score: Score
        let scope: Scope
        let survivors: [Survivor]?
    }

    /// The baseline file at `path`, `~` expanded. Refused, with why (`BaselineRefused`): no file there, one that can't
    /// be read, text that isn't UTF-8 or YAML, a key it doesn't know, such as a misspelled one, a newer format, a score
    /// whose counts no run gives, as more killed than scored, and an entry that names no whole mutant, an outcome it
    /// doesn't know, or a mutant twice.
    static func load(at path: String, using fileManager: FileSystemManager) throws -> BaselineFile {
        let expanded = URL.expandingTilde(path)
        let refusal = { (problem: String) in BaselineRefused(path: path, reasons: [problem]) }
        guard let data = fileManager.contents(atPath: expanded) else {
            guard fileManager.fileExists(atPath: expanded) else {
                throw refusal("There is no baseline file there. Write one with --write-baseline.")
            }
            throw refusal("SwiftMutator can't read it.")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw refusal("It isn't UTF-8.") }
        let written: Written
        do {
            let document = try Yams.load(yaml: text)
            if let version = (document as? [AnyHashable: Any])?["formatVersion"] as? Int, version > formatVersion {
                throw refusal(
                    "Its format is version \(version), newer than this SwiftMutator reads (\(formatVersion)). "
                        + "Use a SwiftMutator as new as the one that wrote it, or write a new one with "
                        + "--write-baseline."
                )
            }
            if let problem = unknownKey(in: document) { throw refusal(problem) }
            written = try YAMLDecoder().decode(Written.self, from: text)
        } catch let refused as BaselineRefused {
            throw refused
        } catch {
            throw refusal("It isn't a baseline file SwiftMutator can read: \(error)")
        }
        return try BaselineFile(path: path, written: written)
    }

    private init(path: String, written: Written) throws {
        let refusal = { (problem: String) in BaselineRefused(path: path, reasons: [problem]) }
        // A hand edit or a merge's conflict can leave counts no run gives, whose score `--max-score-drop` would
        // compare as if it were one: above 100%, or below 0, which turns the comparison around.
        let score = written.score
        guard score.killed >= 0, score.scored >= 0, score.killed <= score.scored else {
            throw refusal(
                "Its score counts killed \(score.killed) of \(score.scored) scored: give scored from 0 up, and "
                    + "killed from 0 to scored."
            )
        }
        var seen: Set<MutantKey> = []
        let survivors = try (written.survivors ?? []).map { entry in
            guard let mutant = MutantKey(wholeDescription: entry.mutant) else {
                throw refusal(
                    "\(entry.mutant) isn't a whole mutant key: give path:line:column Operator, as reports do."
                )
            }
            guard let outcome = BaselineSurvivor.Outcome(rawValue: entry.outcome) else {
                let outcomes = BaselineSurvivor.Outcome.allCases.map(\.rawValue)
                throw refusal(
                    "\(mutant) has the outcome \(entry.outcome): give \(outcomes.dropLast().joined(separator: ", "))"
                        + " or \(outcomes.last ?? "")."
                )
            }
            guard seen.insert(mutant).inserted else {
                throw refusal("\(mutant) is listed more than once.")
            }
            return BaselineSurvivor(
                mutant: mutant,
                outcome: outcome,
                before: entry.before,
                after: entry.after,
                line: entry.line
            )
        }
        self.init(
            path: path,
            formatVersion: written.formatVersion,
            swiftMutator: written.swiftMutator,
            score: written.score,
            scope: BaselineScope(
                operators: written.scope.operators,
                skipCoverage: written.scope.skipCoverage,
                configuration: written.scope.configuration
            ),
            survivors: survivors
        )
    }

    /// What's wrong with the first key in `document` that isn't one of the file's; nil when there's none.
    private static func unknownKey(in document: Any?) -> String? {
        guard let top = document as? [AnyHashable: Any] else { return nil }
        if let problem = unknown(in: top, known: topKeys, of: "the file") { return problem }
        if let score = top["score"] as? [AnyHashable: Any],
           let problem = unknown(in: score, known: scoreKeys, of: "score") {
            return problem
        }
        if let scope = top["scope"] as? [AnyHashable: Any] {
            if let problem = unknown(in: scope, known: scopeKeys, of: "scope") { return problem }
            if let configuration = scope["configuration"] as? [AnyHashable: Any],
               let problem = unknown(in: configuration, known: configurationKeys, of: "scope.configuration") {
                return problem
            }
        }
        for case let survivor as [AnyHashable: Any] in top["survivors"] as? [Any] ?? [] {
            if let problem = unknown(in: survivor, known: survivorKeys, of: "a survivor's entry") { return problem }
        }
        return nil
    }

    /// "colour isn't a key of scope: give operators, skipCoverage, configuration."; nil when `mapping` has no other key
    /// than `known`.
    private static func unknown(in mapping: [AnyHashable: Any], known: [String], of what: String) -> String? {
        guard let key = mapping.keys.map({ "\($0)" }).sorted().first(where: { !known.contains($0) }) else { return nil }
        return "\(key) isn't a key of \(what): give \(known.joined(separator: ", "))."
    }
}

/// Why `--baseline`'s file can't be compared with: it can't be read, or it records a run of another scope, whose
/// mutants differ. Every reason found, in one message, printed as it is (`RunCommand.message(showing:)`). A run exits
/// 8 (`ExitCode.baselineRefused`), before any mutant is tested, and `report` too, before any report is made.
struct BaselineRefused: Error, Equatable, CustomStringConvertible {
    /// The baseline file, as given.
    let path: String
    let reasons: [String]
    /// What would let it through, said once after the reasons; nil when each says it.
    var advice: String?

    var description: String {
        var lines = ["SwiftMutator won't compare the survivors with the baseline file \(Logger.shellQuoted(path)):"]
        lines += reasons.map { "  - " + $0 }
        if let advice {
            lines.append(advice)
        }
        return lines.joined(separator: "\n")
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

/// What became of the baseline file `--write-baseline` asked for, as the run's end, or `report`, says it.
enum BaselineFileSaving: Equatable {
    case saved(path: String)
    /// It couldn't be saved there, as a report that can't be isn't: a warning, which changes no exit status.
    case notSaved(path: String)
    /// None was made, for the reason given, in a clause: "the run stopped before it finished". Only a whole run's
    /// results make one, as one that left mutants out would record their survivors as gone.
    case leftOut(path: String, because: String)

    /// Saves the baseline file of `outcome`, tested by SwiftMutator `version`, at `path`, unless these results leave
    /// some mutants out, by `outcome.whyNoBaselineFile` or `stopped`, a clause that says why they stop short, or
    /// tested none, as every mutant was a build error: its survivors would be none, and every survivor of a later run
    /// new.
    static func save(
        _ outcome: MutationTestOutcome,
        to path: String,
        version: String,
        unless stopped: String? = nil,
        using fileManager: FileSystemManager
    ) -> Self {
        if let reason = stopped ?? outcome.whyNoBaselineFile {
            return .leftOut(path: path, because: reason)
        }
        let mutants = outcome.mutations.filter { $0.key != nil }
        if !mutants.isEmpty, mutants.allSatisfy({ $0.testSuiteOutcome == .buildError }) {
            return .leftOut(path: path, because: "every mutant was a build error, so none was tested")
        }
        guard let scope = outcome.baselineScope else {
            return .leftOut(path: path, because: "the results don't record their scope")
        }
        let file = BaselineFile(of: outcome, scope: scope, version: version, path: path)
        return file.save(using: fileManager) ? .saved(path: path) : .notSaved(path: path)
    }

    /// What a run says of it, with an emoji: "📌 Baseline file saved: muter.baseline.yml".
    var line: String {
        switch self {
        case let .saved(path): "📌 Baseline file saved: \(path.bold)"
        case .notSaved, .leftOut: "⚠️ " + plainLine
        }
    }

    /// What `report` says of it, on standard error, without an emoji.
    var plainLine: String {
        switch self {
        case let .saved(path):
            "Baseline file saved to \(path)"

        case let .notSaved(path):
            "Could not save the baseline file to \(path)"

        case let .leftOut(path, reason):
            "No baseline file was saved to \(path): \(reason), and a baseline file holds a whole run's survivors."
        }
    }
}
