import Foundation
@testable import muterCore
import SwiftParser
import SwiftSyntax
import TestingExtensions

extension MuterTestReport {
    static func make(
        outcome: MutationTestOutcome = .make()
    ) -> MuterTestReport {
        .init(from: outcome)
    }
}

extension MuterTestReport.AppliedMutationOperator {
    static func make(
        mutationPoint: MutationPoint = .make(),
        mutationSnapshot: MutationOperator.Snapshot = .make(),
        testSuiteOutcome: TestSuiteOutcome = .passed,
        killingTests: MutationTestOutcome.KillingTests? = nil,
        killedOnlyBySuspectTests: Bool? = nil
    ) -> Self {
        Self(
            mutationPoint: mutationPoint,
            mutationSnapshot: mutationSnapshot,
            testSuiteOutcome: testSuiteOutcome,
            killingTests: killingTests,
            killedOnlyBySuspectTests: killedOnlyBySuspectTests
        )
    }
}

extension MutationOperator.Snapshot {
    static func make(
        before: String = "",
        after: String = "",
        description: String = ""
    ) -> Self {
        Self(
            before: before,
            after: after,
            description: description
        )
    }
}

extension MutationTestOutcome {
    static func make(
        mutations: [Mutation] = [],
        coverage: Coverage = .null
    ) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            coverage: coverage
        )
    }
}

extension EarlyEnd {
    /// Mutation testing that stopped after testing a mutant with each of `tested`, of `discovered`.
    static func make(
        reason: ResultsEnd.Reason = .interrupted,
        detail: String? = nil,
        tested: [TestSuiteOutcome] = [.failed, .passed],
        discovered: Int = 4,
        reused: Int = 0
    ) -> EarlyEnd {
        EarlyEnd(
            reason: reason,
            detail: detail,
            outcome: MutationTestOutcome(mutations: tested.map { .make(testSuiteOutcome: $0) }),
            discovered: discovered,
            reused: reused
        )
    }
}

extension ResumeSummary {
    static func make(
        path: String = "/logs/results.jsonl",
        reused: Int = 2,
        toTest: Int = 2,
        retestedBecause: [ResumePlan.Reason: Int] = [.notRecorded: 2],
        forced: [String] = [],
        waived: [String] = [],
        notices: [String] = []
    ) -> ResumeSummary {
        ResumeSummary(
            path: path,
            reused: reused,
            toTest: toTest,
            retestedBecause: retestedBecause,
            forced: forced,
            waived: waived,
            notices: notices
        )
    }
}

extension MutationTestOutcome.Mutation {
    static func make(
        testSuiteOutcome: TestSuiteOutcome = .passed,
        point: MutationPoint = .make(),
        snapshot: MutationOperator.Snapshot = .null,
        originalProjectDirectoryUrl: URL = URL(fileURLWithPath: ""),
        mutatedProjectDirectoryURL: URL = URL(fileURLWithPath: ""),
        killingTests: MutationTestOutcome.KillingTests? = nil
    ) -> Self {
        Self(
            testSuiteOutcome: testSuiteOutcome,
            mutationPoint: point,
            mutationSnapshot: snapshot,
            originalProjectDirectoryUrl: originalProjectDirectoryUrl,
            mutatedProjectDirectoryURL: mutatedProjectDirectoryURL,
            killingTests: killingTests
        )
    }
}

extension MutationTestOutcome.KillingTests {
    /// A run that exited by itself without a line that shows a failed test.
    static let noneNamed = Self(tests: [], count: 0, isComplete: true)
}

extension MutationTestOutcome {
    /// Killed mutants in 11 files with the tests that failed for them, as runs record them: 14 tests, the widest in 9
    /// files, so none is suspect. One run stopped at its first failed test, one kill names no test and one has none
    /// recorded; a crash, a time-out and a survivor aren't counted. One test is XCTest's, and one's name is longer
    /// than the plain report shows.
    static var withKillingTests: MutationTestOutcome {
        let shared = FailedTestLine.FailedTest(name: "parsesEveryRule()", location: "ParserTests.swift:12:9")
        let longName = FailedTestLine.FailedTest(
            name: #""adding every number in a long list gives the same total in any order""#,
            location: "File02Tests.swift:8:5"
        )
        let xctest = FailedTestLine.FailedTest(name: "-[AppTests.ParserTests testParsesEmptyInput]", location: nil)
        let everyFile = (1 ... 11).map { file in
            mutant(
                .failed,
                file,
                3,
                file <= 9
                    ? KillingTests(tests: [focused(file), shared], count: 2, isComplete: true)
                    : KillingTests(tests: [focused(file)], count: 1, isComplete: true)
            )
        }
        return .make(mutations: everyFile + [
            mutant(.failed, 1, 7, KillingTests(tests: [focused(1)], count: 3, isComplete: false)),
            mutant(.failed, 2, 9, KillingTests(tests: [longName, focused(2)], count: 2, isComplete: true)),
            mutant(.failed, 3, 12, .noneNamed),
            mutant(.failed, 4, 15, nil),
            mutant(.runtimeError, 5, 18, KillingTests(tests: [focused(5)], count: 1, isComplete: true)),
            mutant(.passed, 6, 21, nil),
            mutant(.failed, 7, 24, KillingTests(tests: [xctest], count: 1, isComplete: true)),
            mutant(.timeout, 8, 27, KillingTests(tests: [], count: 0, isComplete: false)),
        ])
    }

    /// Killed mutants in 12 files with two suspect tests: timing() failed for a mutant in each, order() in 10. The
    /// kills in files 1 to 6 name a focused test too; those in files 7 to 12 name only suspects, and the run in file
    /// 12 stopped at its first failed test, so the score without them is a lower bound. A crash only timing() failed
    /// for stays a kill, and one mutant survived.
    static var withSuspectTests: MutationTestOutcome {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let order = FailedTestLine.FailedTest(name: "order()", location: "OrderTests.swift:4:5")
        let everyFile = (1 ... 12).map { file in
            let tests = (file <= 6 ? [focused(file)] : []) + [timing] + (file >= 2 ? [order] : [])
            return file == 12
                ? mutant(.failed, file, 3, KillingTests(tests: [timing], count: 1, isComplete: false))
                : mutant(.failed, file, 3, KillingTests(tests: tests, count: tests.count, isComplete: true))
        }
        return .make(mutations: everyFile + [
            mutant(.runtimeError, 7, 8, KillingTests(tests: [timing], count: 1, isComplete: true)),
            mutant(.passed, 8, 12, nil),
        ])
    }
}

private extension MutationTestOutcome {
    /// The test that fails for a mutant in `file` alone.
    static func focused(_ file: Int) -> FailedTestLine.FailedTest {
        FailedTestLine.FailedTest(
            name: String(format: "focused%02d()", file),
            location: String(format: "File%02dTests.swift:3:5", file)
        )
    }

    /// A mutant on `line` of `file`, with `killingTests` recorded.
    static func mutant(
        _ outcome: TestSuiteOutcome,
        _ file: Int,
        _ line: Int,
        _ killingTests: KillingTests?
    ) -> Mutation {
        Mutation.make(
            testSuiteOutcome: outcome,
            point: .make(
                filePath: String(format: "/tmp/project/Sources/File%02d.swift", file),
                position: .init(integerLiteral: line)
            ),
            killingTests: killingTests
        )
    }
}

extension MuterTestReport.FileReport {
    static func make(
        name: String,
        path: String,
        mutationScore: Int,
        appliedOperators: [MuterTestReport.AppliedMutationOperator]
    ) -> Self {
        Self(
            fileName: name,
            path: path,
            mutationScore: mutationScore,
            appliedOperators: appliedOperators
        )
    }
}

extension MuterTestReport.AppliedMutationOperator {
    static func make(
        mutationOperator: MutationOperator.Id = .logicalOperator,
        position: SwiftSyntax.SourceLocation = .init(integerLiteral: 0),
        mutationSnapshot: MutationOperator.Snapshot = .null,
        testOutcome: TestSuiteOutcome = .passed
    ) -> Self {
        Self(
            mutationPoint: .make(
                mutationOperatorId: mutationOperator,
                filePath: "filePath",
                position: MutationPosition(sourceLocation: position)
            ), mutationSnapshot: mutationSnapshot,
            testSuiteOutcome: testOutcome
        )
    }
}

extension MutationPoint {
    static func make(
        mutationOperatorId: MutationOperator.Id = .logicalOperator,
        filePath: String = "",
        position: MutationPosition = 10
    ) -> Self {
        Self(
            mutationOperatorId: mutationOperatorId,
            filePath: filePath,
            position: position
        )
    }
}

func nextMutationOperator(
    _ index: Int
) -> MutationOperator.Id {
    MutationOperator.Id.allCases[circular: index]
}

func nextMutationTestOutcome(
    _ index: Int
) -> TestSuiteOutcome {
    TestSuiteOutcome.allCases[circular: index]
}

extension MutationPosition: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(
            sourceLocation: .init(integerLiteral: value)
        )
    }
}

extension SwiftSyntax.SourceLocation: @retroactive ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(line: value, column: value, offset: value, file: "")
    }
}

extension Array {
    subscript(circular index: Int) -> Element {
        self[Swift.max(index, 1) % count]
    }
}

extension Coverage {
    static func make(
        percent: Int = 0,
        filesWithoutCoverage: [FilePath] = [],
        functionsCoverage: FunctionsCoverage = .null
    ) -> Coverage {
        Coverage(
            percent: percent,
            filesWithoutCoverage: filesWithoutCoverage,
            functionsCoverage: functionsCoverage
        )
    }
}

extension Region {
    static func make(
        lineStart: Int = 0,
        columnStart: Int = 0,
        lineEnd: Int = 0,
        columnEnd: Int = 0,
        executionCount: Int = 0,
        kind: Region.Kind = .code
    ) -> Region {
        Region(
            lineStart: lineStart,
            columnStart: columnStart,
            lineEnd: lineEnd,
            columnEnd: columnEnd,
            executionCount: executionCount,
            kind: kind
        )
    }
}

extension Run.Options {
    static func make(
        filesToMutate: [String] = [],
        reportFormat: ReportFormat = .plain,
        reportURL: URL? = nil,
        mutationOperatorsList: MutationOperatorList = [],
        skipCoverage: Bool = false,
        skipUpdateCheck: Bool = false,
        configurationURL: URL? = nil,
        testPlanURL: URL? = nil,
        createTestPlan: Bool = false,
        resumeURL: URL? = nil,
        resumeIgnoring: [String] = [],
        forceResume: Bool = false
    ) -> Self {
        .init(
            filesToMutate: filesToMutate,
            reportFormat: reportFormat,
            reportURL: reportURL,
            mutationOperatorsList: mutationOperatorsList,
            skipCoverage: skipCoverage,
            skipUpdateCheck: skipUpdateCheck,
            configurationURL: configurationURL,
            testPlanURL: testPlanURL,
            createTestPlan: createTestPlan,
            resumeURL: resumeURL,
            resumeIgnoring: resumeIgnoring,
            forceResume: forceResume
        )
    }
}

typealias SchemataMutationMappings = (source: String, schemata: MutationSchemata)

extension SchemataMutationMapping {
    static func make(
        filePath: String = "",
        _ mappings: SchemataMutationMappings...
    ) throws -> SchemataMutationMapping {
        let schemataMutationMapping = SchemataMutationMapping(filePath: filePath)

        for (source, schemata) in mappings {
            let codeBlockSyntax = try sourceCode(source).statements

            for schema in schemata {
                schemataMutationMapping.add(codeBlockSyntax, schema)
            }
        }

        return schemataMutationMapping
    }
}

extension MutationSchema {
    static func make(
        filePath: String = "",
        mutationOperatorId: MutationOperator.Id = .ror,
        syntaxMutation: String = "",
        position: MutationPosition = .null,
        snapshot: MutationOperator.Snapshot = .null
    ) throws -> MutationSchema {
        try MutationSchema(
            filePath: filePath,
            mutationOperatorId: mutationOperatorId,
            syntaxMutation: sourceCode(syntaxMutation).statements,
            position: position,
            snapshot: snapshot
        )
    }
}

func sourceCode(
    _ source: String
) throws -> SourceFileSyntax {
    Parser.parse(source: source)
}

extension MuterConfiguration {
    static func fromFixture(at path: String) -> MuterConfiguration? {
        guard let data = FileManager.default.contents(atPath: path),
              let configuration = try? MuterConfiguration(from: data)
        else {
            fatalError("Unable to load a valid Muter configuration file from \(path)")
        }
        return configuration
    }
}

/// No field is left at its default, so a copy that drops one no longer equals this, and every configuration key
/// differs from the default's. `test_configurationWithEveryFieldSet_leavesNoFieldAtItsDefault` fails until a new
/// field is set here, which then reaches the copy tests and `test_everyConfigurationKeyButTwo_isCompared`.
func configurationWithEveryFieldSet(
    executable: String = "/usr/bin/swift",
    timeout: Double? = 30,
    failedTestLinesAreReliable: Bool = false
) -> MuterConfiguration {
    let configuration = MuterConfiguration(
        executable: executable,
        arguments: ["test"],
        excludeList: ["Generated"],
        excludeCallList: ["print"],
        coverageThreshold: 80,
        testSuiteTimeOut: timeout,
        buildSystem: .swift,
        mutationTestWorkers: 4,
        stopAtFirstFailure: false
    )
    return failedTestLinesAreReliable ? configuration : configuration.withUnreliableFailedTestLines()
}

extension MutationPosition {
    static var firstPosition: MutationPosition {
        MutationPosition(utf8Offset: 0, line: 0, column: 0)
    }
}

extension MuterTestPlan {
    static func make(
        mutatedProjectPath: String = "",
        projectCoverage: Int = 0,
        mappings: [SchemataMutationMapping] = []
    ) -> MuterTestPlan {
        MuterTestPlan(
            mutatedProjectPath: mutatedProjectPath,
            projectCoverage: projectCoverage,
            mappings: mappings
        )
    }

    var toData: Data {
        (try? JSONEncoder().encode(self)) ?? .init()
    }
}

extension MutationTestLog {
    static func make(
        mutationPoint: MutationPoint? = nil,
        testLog: String = "",
        timePerBuildTestCycle: TimeInterval? = nil,
        remainingMutationPointsCount: Int? = nil
    ) -> MutationTestLog {
        MutationTestLog(
            mutationPoint: mutationPoint,
            testLog: testLog,
            timePerBuildTestCycle: timePerBuildTestCycle,
            remainingMutationPointsCount: remainingMutationPointsCount
        )
    }
}

extension Provenance {
    static var fixture: Provenance {
        Provenance(
            swiftMutator: .init(
                version: "1.0.0",
                executablePath: "/usr/local/bin/swift-mutator",
                executableSHA256: "9f2c"
            ),
            toolchain: .init(
                testCommandVersion: "Apple Swift version 6.4",
                testExecutableSHA256: nil,
                environment: ["SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"]
            ),
            processIdentifier: 81234,
            host: "host",
            arguments: ["-c", "mutation.conf.yml", "--skip-coverage"]
        )
    }
}

extension ResultsHeader {
    /// 2026-10-04T13:16:04.500Z: a whole number of milliseconds that a binary fraction holds exactly, so a header
    /// read back from a results file equals the one written.
    static let fixedStart = Date(timeIntervalSince1970: 1_791_119_764.5)

    static func make(
        formatVersion: Int = ResultsCoding.formatVersion,
        session: Int = 1,
        startedAt: Date = fixedStart,
        projectPath: String = "/project",
        mutatedProjectPath: String = "/project_mutated",
        coverage: CoverageSummary? = nil,
        newVersion: String = "",
        mutantsDiscovered: Int = 3,
        mutantsToTest: Int = 3,
        project: ProjectTree? = nil,
        provenance: Provenance = .fixture,
        configuration: MuterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
        operators: [String] = ["RelationalOperatorReplacement"],
        filesToMutate: [String] = [],
        skipCoverage: Bool = true,
        usingTestPlan: Bool = false,
        mutantsReused: Int? = nil,
        waived: [String]? = nil,
        forced: [String]? = nil
    ) -> ResultsHeader {
        ResultsHeader(
            formatVersion: formatVersion,
            session: session,
            startedAt: startedAt,
            provenance: provenance,
            configuration: configuration,
            operators: operators,
            filesToMutate: filesToMutate,
            skipCoverage: skipCoverage,
            usingTestPlan: usingTestPlan,
            projectPath: projectPath,
            mutatedProjectPath: mutatedProjectPath,
            logDirectory: "/project_muter_logs/run",
            coverage: coverage,
            newVersion: newVersion,
            baselineSeconds: 32.125,
            timeoutSeconds: 96.5,
            timeoutIsDefault: true,
            workers: 1,
            stopsAtFirstFailure: false,
            failedTestLinesAreReliable: true,
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsToTest,
            project: project,
            mutantsReused: mutantsReused,
            waived: waived,
            forced: forced
        )
    }
}

extension MutantResult {
    static func make(
        session: Int = 1,
        path: String = "Sources/Sum.swift",
        line: Int = 73,
        column: Int = 22,
        occurrence: Int = 0,
        utf8Offset: Int = 3361,
        mutationOperatorId: MutationOperator.Id = .ror,
        switchID: String? = nil,
        snapshot: MutationOperator.Snapshot = .make(before: ">", after: "<", description: "changed > to <"),
        outcome: TestSuiteOutcome = .failed,
        endedBy: TestRun.Ending = .exited,
        finishedAt: Date = ResultsHeader.fixedStart.addingTimeInterval(31.25),
        killedBy: [FailedTestLine.FailedTest]? = nil,
        failedTestCount: Int? = nil,
        fileSHA256: String? = nil
    ) -> MutantResult {
        MutantResult(
            session: session,
            path: path,
            line: line,
            column: column,
            occurrence: occurrence,
            utf8Offset: utf8Offset,
            mutationOperatorId: mutationOperatorId,
            switchID: switchID ?? "Sum_\(mutationOperatorId.rawValue)_\(line)_\(column)_\(utf8Offset)",
            snapshot: snapshot,
            outcome: outcome,
            endedBy: endedBy,
            exitStatus: endedBy == .exited ? (outcome == .passed ? 0 : 1) : nil,
            durationSeconds: 31.25,
            worker: 0,
            finishedAt: finishedAt,
            killedBy: killedBy,
            failedTestCount: failedTestCount ?? killedBy?.count,
            firstFailedTestLine: nil,
            log: "\(mutationOperatorId.rawValue) @ Sum.swift-\(line)-\(column).log",
            fileSHA256: fileSHA256
        )
    }
}

extension ResultsEnd {
    static func make(
        session: Int = 1,
        endedAt: Date = ResultsHeader.fixedStart.addingTimeInterval(100.5),
        reason: Reason = .finished,
        detail: String? = nil,
        testDurationSeconds: Double = 100.5,
        recorded: Int = 3
    ) -> ResultsEnd {
        ResultsEnd(
            session: session,
            endedAt: endedAt,
            reason: reason,
            detail: detail,
            testDurationSeconds: testDurationSeconds,
            recorded: recorded
        )
    }
}

/// `lines` as a results file holds them, each on a line of its own.
func resultsFileData(_ lines: [any Encodable]) throws -> Data {
    let encoder = ResultsCoding.encoder
    return try lines.reduce(into: Data()) { data, line in
        data += try encoder.encode(line) + Data("\n".utf8)
    }
}

extension ResumeState {
    /// The resume of the results file at `path`, which holds `lines`, opened as `file`.
    static func make(
        path: String = "/project_muter_logs/session 1/results.jsonl",
        lines: [any Encodable],
        file: ResultsRecording,
        provenance: Provenance = .fixture,
        forced: [String] = [],
        notices: [String] = []
    ) throws -> ResumeState {
        let recorded = try RecordedResults.read(resultsFileData(lines), path: path)
        guard let lastHeader = recorded.headers.last else {
            throw ResultsFileError.notAResultsFile(path: path)
        }
        return ResumeState(
            path: path,
            file: file,
            recorded: recorded,
            lastHeader: lastHeader,
            provenance: provenance,
            forced: forced,
            notices: notices
        )
    }
}
