import Foundation

/// A mutant the SARIF report gives as a result, with all its result says.
struct SarifFinding {
    /// The key its fingerprint has in `partialFingerprints`, for tools other than GitHub, which reads only
    /// `lineHashKey`. A new way of making it would take a new version, so that a tool doesn't match one way's
    /// fingerprints against the other's.
    static let fingerprintKey = "swiftMutatorMutant/v1"

    let relativePath: String
    let operatorId: MutationOperator.Id
    let level: SarifLog.Level
    let message: String
    let span: SourceSpan
    /// The code `span` covers, as its file holds it; nil when not known.
    let snippet: String?
    /// The lines `span` is on, whole, as its file holds them, when `span` doesn't cover them whole; nil otherwise.
    let context: String?
    let fingerprint: String

    /// Each mutant of `outcome` the tests didn't kill, with its columns and its fingerprint from its original file,
    /// which `read` reads.
    static func all(of outcome: MutationTestOutcome, reading read: ReadFile) -> [Self] {
        let paths = Set(outcome.mutations.map(\.originalProjectPath))
        let files = OriginalFiles(paths, read: read)
        let lines = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            files.text(at: path).map { (path, SourceLines($0)) }
        })
        let repeats = lines.mapValues(\.repeatsAbove)
        return outcome.mutations.compactMap { mutation in
            guard let findingLevel = level(of: mutation.testSuiteOutcome) else { return nil }
            let fileLines = lines[mutation.originalProjectPath]
            let (sourceSpan, isFound) = SourceSpan.of(mutation, in: fileLines)
            let whole = SourceSpan(
                start: .init(line: sourceSpan.start.line, column: 1),
                end: fileLines?.span(ofLine: sourceSpan.end.line)?.end ?? sourceSpan.end
            )
            return Self(
                relativePath: mutation.relativePath,
                operatorId: mutation.point.mutationOperatorId,
                level: findingLevel,
                message: message(of: mutation),
                span: sourceSpan,
                snippet: fileLines?.text(of: sourceSpan),
                context: whole == sourceSpan ? nil : fileLines?.text(of: whole),
                // Code not found spans its whole line, alike for each mutant on it, so it is fingerprinted from its
                // recorded place, as for a file that can't be read.
                fingerprint: fingerprint(
                    of: mutation,
                    span: sourceSpan,
                    lines: isFound ? fileLines : nil,
                    repeats: repeats[mutation.originalProjectPath]
                )
            )
        }
    }

    /// Survivors and timeouts are warnings, as the score counts both as survivors, and a mutant no test reached is a
    /// note; any other isn't a result.
    private static func level(of outcome: TestSuiteOutcome) -> SarifLog.Level? {
        switch outcome {
        case .passed, .timeout: .warning
        case .noCoverage: .note
        case .failed, .runtimeError, .buildError: nil
        }
    }

    /// As the Xcode format words its warning: "Your test suite did not kill this mutant: changed == to !=", and
    /// "(timed out)" after a timeout's.
    private static func message(of mutation: MutationTestOutcome.Mutation) -> String {
        let description = mutation.snapshot.description
        return XcodeReporter.verdict(of: mutation.testSuiteOutcome)
            + (description.isEmpty ? "" : ": " + description)
            + (mutation.testSuiteOutcome == .timeout ? " (timed out)" : "")
    }

    /// The result, under the rule at `ruleIndex` in the driver's rules, with its path under `projectFolder`
    /// (`artifactLocation(of:under:)`).
    func result(ruleIndex: Int, projectFolder: String = "") -> SarifLog.Result {
        let place = SarifLog.PhysicalLocation(
            artifactLocation: Self.artifactLocation(of: relativePath, under: projectFolder),
            region: SarifLog.Region(
                startLine: span.start.line,
                startColumn: span.start.column,
                endLine: span.end.line,
                endColumn: span.end.column,
                snippet: snippet.map(SarifLog.Snippet.init)
            ),
            contextRegion: context.map { context in
                SarifLog.ContextRegion(
                    startLine: span.start.line,
                    endLine: span.end.line,
                    snippet: SarifLog.Snippet(text: context)
                )
            }
        )
        return SarifLog.Result(
            ruleId: operatorId.rawValue,
            ruleIndex: ruleIndex,
            level: level,
            message: SarifLog.Message(text: message),
            locations: [SarifLog.Location(physicalLocation: place)],
            partialFingerprints: [Self.fingerprintKey: fingerprint, Self.lineHashKey: fingerprint]
        )
    }

    /// A path in the project as a URI under `%SRCROOT%`, the work tree the project is in, so under `projectFolder`,
    /// the project's own folder in it ("" for the work tree itself): GitHub reads a relative path from the
    /// repository's root, whatever `%SRCROOT%` says. One outside the project is an absolute `file://` URI. A `:` is
    /// encoded too, as a relative URI whose first part holds one would read as a scheme.
    static func artifactLocation(
        of relativePath: String,
        under projectFolder: String = ""
    ) -> SarifLog.ArtifactLocation {
        guard !relativePath.hasPrefix("/") else {
            return SarifLog.ArtifactLocation(uri: URL(fileURLWithPath: relativePath).absoluteString, uriBaseId: nil)
        }
        let path = projectFolder.isEmpty ? relativePath : projectFolder + "/" + relativePath
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(":")
        return SarifLog.ArtifactLocation(
            uri: path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path,
            uriBaseId: SarifReporter.sourceRoot
        )
    }
}

extension SarifFinding: Comparable {
    /// By path, line, column and operator; then warnings first, then by fingerprint, so the order is always the same.
    static func < (lhs: Self, rhs: Self) -> Bool {
        let left = (lhs.relativePath, lhs.span.start.line, lhs.span.start.column, lhs.operatorId.rawValue)
        let right = (rhs.relativePath, rhs.span.start.line, rhs.span.start.column, rhs.operatorId.rawValue)
        guard left == right else { return left < right }
        return (lhs.level == .warning ? 0 : 1, lhs.fingerprint) < (rhs.level == .warning ? 0 : 1, rhs.fingerprint)
    }
}

extension SarifFinding {
    /// The key GitHub code scanning matches results by across runs, the only one of `partialFingerprints` it reads.
    /// `github/codeql-action/upload-sarif` fills it from a hash of the line when a result has none, which two mutants
    /// on one line would share, so the report gives each mutant's own fingerprint here too.
    static let lineHashKey = "primaryLocationLineHash"

    /// A mutant's fingerprint: a SHA-256 of what it changes, never of where, so a line moved by an edit above keeps
    /// its alert. That is its file's path, its operator, the text of the line its code starts on, without the spaces
    /// around it, its code before and after, how many lines above hold the same text (`repeats`, its file's
    /// `repeatsAbove`), and where its code starts on that line, after its indent. Both are counted in the file, not
    /// among the mutants a run tested, so a run of some of them gives each the fingerprint a whole run does. Without
    /// its file's lines, or its code in them, the mutant's recorded line and column stand in for them.
    static func fingerprint(
        of mutation: MutationTestOutcome.Mutation,
        span: SourceSpan,
        lines: SourceLines?,
        repeats: [Int]?
    ) -> String {
        let line = lines?.line(span.start.line)
        let place = line.map { line in
            let indent = line.prefix { $0.isWhitespace }.utf16.count
            let repeated = repeats.flatMap { $0.indices.contains(span.start.line - 1) ? $0[span.start.line - 1] : nil }
            return "\(repeated ?? 0):\(span.start.column - 1 - indent)"
        } ?? "\(mutation.point.position.line):\(mutation.point.position.column)"
        let parts = [
            mutation.relativePath,
            mutation.point.mutationOperatorId.rawValue,
            (line ?? "").trimmingCharacters(in: .whitespaces),
            mutation.snapshot.before,
            mutation.snapshot.after,
            place,
        ]
        return FileDigest.sha256(of: Data(parts.joined(separator: "\u{0}").utf8))
    }
}

extension SourceLines {
    /// For each line, how many lines above it hold the same text, without the spaces around it.
    var repeatsAbove: [Int] {
        var seen: [String: Int] = [:]
        return (1...max(1, count)).map { number in
            let text = (line(number) ?? "").trimmingCharacters(in: .whitespaces)
            defer { seen[text, default: 0] += 1 }
            return seen[text, default: 0]
        }
    }
}
