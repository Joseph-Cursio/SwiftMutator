import Foundation

/// The Stryker report (`-f stryker`): JSON in the mutation-testing-elements schema (`StrykerReport`), for Stryker's
/// dashboard and its report viewer, with each file's source, so the viewer can show every mutant in its code. The same
/// for the same outcome, and the same files: sorted keys, and each file's mutants by line, column and id.
///
/// Stryker's score counts a timeout as detected, as its `Timeout` status is; SwiftMutator's counts it as a survivor. So
/// the viewer's score is higher than SwiftMutator's when a mutant timed out.
struct StrykerReporter: Reporter {
    @Dependency(\.readSourceFile)
    private var readSourceFile: ReadFile
    /// The version the report names, which a test fixes so that a release doesn't change its output.
    private let swiftMutatorVersion: String

    init(swiftMutatorVersion: String = version) {
        self.swiftMutatorVersion = swiftMutatorVersion
    }

    func report(from outcome: MutationTestOutcome) -> String {
        SortedJSON.encoded(strykerReport(of: outcome))
    }

    /// The report of `outcome`. Each file is read as it is now: a file changed since it was tested, as `report` of an
    /// old results file may find it, shows today's code, which the mutants' places may no longer match.
    func strykerReport(of outcome: MutationTestOutcome) -> StrykerReport {
        let originals = ReportedFile.originals(of: outcome)
        let sources = OriginalFiles(originals.values, read: readSourceFile)
        let byFile = Dictionary(grouping: outcome.mutations.indices) { outcome.mutations[$0].relativePath }
        let files = originals.keys.map { path -> (String, StrykerReport.File) in
            let source = originals[path].flatMap(sources.text(at:))
            let lines = source.map(SourceLines.init)
            let mutants = (byFile[path] ?? []).map { index in
                Self.mutant(outcome.mutations[index], fallbackId: "mutant \(index + 1)", lines: lines)
            }
            return (path, StrykerReport.File(language: "swift", source: source ?? "", mutants: mutants.sorted()))
        }
        let tests = Set(outcome.mutations.flatMap { Self.killingTests(of: $0) ?? [] }).sorted()
            .map { StrykerReport.Test(id: $0, name: $0) }
        return StrykerReport(
            schemaVersion: "2",
            thresholds: StrykerReport.Thresholds(high: 80, low: 60),
            projectRoot: outcome.projectPath.isEmpty ? nil : outcome.projectPath,
            framework: StrykerReport.Framework(name: "SwiftMutator", version: swiftMutatorVersion),
            files: Dictionary(files) { first, _ in first },
            testFiles: tests.isEmpty ? nil : ["": StrykerReport.TestFile(tests: tests)]
        )
    }

    /// `mutation` as Stryker has it, by its key, or by `fallbackId` without one; its columns from `lines`, its file's.
    private static func mutant(
        _ mutation: MutationTestOutcome.Mutation,
        fallbackId: String,
        lines: SourceLines?
    ) -> StrykerReport.Mutant {
        let span = SourceSpan.of(mutation, in: lines).span
        return StrykerReport.Mutant(
            id: mutation.key?.description ?? fallbackId,
            mutatorName: mutation.point.mutationOperatorId.rawValue,
            replacement: MutantDiff.replacement(mutation.snapshot, mutation.point.mutationOperatorId),
            description: mutation.snapshot.description,
            location: StrykerReport.Location(span),
            status: status(of: mutation.testSuiteOutcome),
            statusReason: statusReason(of: mutation),
            killedBy: killingTests(of: mutation),
            duration: mutation.durationSeconds.map { Int(($0 * 1_000).rounded()) }
        )
    }

    /// A crash is a kill, as SwiftMutator's score counts it, and a timeout is Stryker's own `Timeout`, which its score
    /// counts as detected.
    private static func status(of outcome: TestSuiteOutcome) -> StrykerReport.Status {
        switch outcome {
        case .failed, .runtimeError: .killed
        case .passed: .survived
        case .timeout: .timeout
        case .buildError: .compileError
        case .noCoverage: .noCoverage
        }
    }

    /// Why a kill was a crash, and why a build error may compile; nil for any other.
    private static func statusReason(of mutation: MutationTestOutcome.Mutation) -> String? {
        switch mutation.testSuiteOutcome {
        case .runtimeError:
            return "The tests crashed with this mutant on, which counts as a kill."

        case .buildError where mutation.leftOutWithOthers:
            return "Left out of the build with other mutants, as the compiler's error could be any of theirs, "
                + "so it may compile."

        default:
            return nil
        }
    }

    /// Every test recorded failing, by name, each once, in the order they failed; nil when none was.
    private static func killingTests(of mutation: MutationTestOutcome.Mutation) -> [String]? {
        var seen: Set<String> = []
        let names = (mutation.killingTests?.tests ?? []).map(\.name).filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names
    }
}

extension StrykerReport.Mutant: Comparable {
    /// By line, column and id, so a file's mutants are in one order whatever order they were tested in.
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.location.start.line, lhs.location.start.column, lhs.id)
            < (rhs.location.start.line, rhs.location.start.column, rhs.id)
    }
}

/// The files a Stryker or SARIF report names.
enum ReportedFile {
    /// Each file with a mutant, and each no test ran, by its path relative to the project, with its original file's
    /// path, which the reports read. A file outside the project keeps its absolute path.
    static func originals(of outcome: MutationTestOutcome) -> [String: String] {
        var originals: [String: String] = [:]
        for mutation in outcome.mutations {
            originals[mutation.relativePath] = mutation.originalProjectPath
        }
        for path in outcome.coverage.filesWithoutCoverage {
            let relativePath = outcome.relativePath(of: path)
            if originals[relativePath] == nil {
                originals[relativePath] = RepoRelativePath.resolve(relativePath, under: outcome.projectPath)
            }
        }
        return originals
    }
}
