import Foundation

/// How a results file's lines are written and read: JSON Lines, one record per line, each with a `kind`.
enum ResultsCoding {
    /// Changes only for a change that a reader of the earlier format would misread. A new key or a new kind needs
    /// none: readers ignore keys and skip kinds they don't know.
    static let formatVersion = 1

    /// Sorted keys, so lines read and compare alike; slashes unescaped, so paths read as paths; never pretty-printed,
    /// so a record is one line, any line break in it escaped. Dates are ISO 8601 in UTC, to the millisecond.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(text(of: date))
        }
        return encoder
    }

    /// Reads dates as `encoder` writes them, or without fractional seconds.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    /// Every line's first question: what kind of record it is.
    struct Kind: Decodable {
        let kind: String
    }

    /// `date` in UTC to the nearest millisecond, `2026-10-04T13:16:04.512Z`. Rounded here rather than by
    /// `ISO8601FormatStyle`, which truncates: a date read back from `.004` is a hair under it, and would be written
    /// back as `.003`.
    private static func text(of date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let time = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: seconds)
        )
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ",
            time.year ?? 0,
            time.month ?? 0,
            time.day ?? 0,
            time.hour ?? 0,
            time.minute ?? 0,
            time.second ?? 0,
            Int(milliseconds - seconds * 1000)
        )
    }

    private static func date(from text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()
}

/// A run's coverage, as its report shows it.
struct CoverageSummary: Codable, Equatable {
    let percent: Int
    let filesWithoutCoverage: [String]
}

/// A session's first line: where its results came from, and what they were tested with. Written once the baseline
/// passes, so a run whose baseline fails leaves no results file.
struct ResultsHeader: Codable, Equatable {
    var kind = "header"
    let formatVersion: Int
    /// 1 for now; a resumed run adds the next session to the same file.
    let session: Int
    /// When mutation testing started, which the session's test duration is measured from.
    let startedAt: Date
    let provenance: Provenance
    /// The configuration as loaded, under its own keys: not the effective one, which `timeoutSeconds`,
    /// `stopsAtFirstFailure` and `failedTestLinesAreReliable` describe.
    let configuration: MuterConfiguration
    /// The operators asked for, by name, sorted.
    let operators: [String]
    let filesToMutate: [String]
    let skipCoverage: Bool
    let usingTestPlan: Bool
    let projectPath: String
    let mutatedProjectPath: String
    /// The folder of the session's kept logs, which each mutant's `log` names a file in.
    let logDirectory: String
    /// Absent when the run has no coverage, as its report then shows none.
    let coverage: CoverageSummary?
    /// The newer SwiftMutator version the update check found, or "", which the HTML report shows.
    let newVersion: String
    /// How long the baseline run took.
    let baselineSeconds: Double?
    /// The time limit for a mutant's run: the configured one, or else the default the baseline set.
    let timeoutSeconds: Double?
    let timeoutIsDefault: Bool
    let workers: Int
    let stopsAtFirstFailure: Bool
    let failedTestLinesAreReliable: Bool
    let mutantsDiscovered: Int
    let mutantsToTest: Int
    /// The project's files, as the mutated copy held them before discovery rewrote it. Absent when the run tested a
    /// test plan, which copies nothing.
    let project: ProjectTree?
}

extension ResultsHeader {
    /// The header of a session that tests `state`'s mutants with `configuration`, the effective configuration: the
    /// default time limit applied, and failed-test lines judged by the baseline. `logDirectory` is the run's.
    init(
        session: Int,
        startedAt: Date,
        state: AnyMutationTestState,
        logDirectory: String,
        configuration: MuterConfiguration,
        baselineSeconds: Double?,
        workers: Int,
        mutantsDiscovered: Int,
        mutantsToTest: Int,
        provenance: Provenance
    ) {
        let coverage = state.projectCoverage
        self.init(
            formatVersion: ResultsCoding.formatVersion,
            session: session,
            startedAt: startedAt,
            provenance: provenance,
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            logDirectory: logDirectory,
            coverage: coverage == .null
                ? nil
                : CoverageSummary(percent: coverage.percent, filesWithoutCoverage: coverage.filesWithoutCoverage),
            newVersion: state.newVersion,
            baselineSeconds: baselineSeconds,
            timeoutSeconds: configuration.testSuiteTimeout,
            timeoutIsDefault: state.muterConfiguration.testSuiteTimeout == nil,
            workers: workers,
            stopsAtFirstFailure: configuration.stopsAtFirstFailure,
            failedTestLinesAreReliable: configuration.failedTestLinesAreReliable,
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsToTest,
            project: state.projectTree
        )
    }
}

/// One tested mutant: its key, how its run ended, and the tests that killed it. Only a run that wasn't cancelled
/// has one, so `endedBy` is never `cancelled`.
struct MutantResult: Codable, Equatable {
    var kind = "mutant"
    let session: Int
    /// The key's fields (`MutantKey`).
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    /// The mutant's offset in the file as SwiftMutator prepared it.
    let utf8Offset: Int
    let mutationOperatorId: MutationOperator.Id
    /// `MutationSchema.id`, the ID that switched the mutant on: under `swift test`, the contents of the worker's
    /// active-mutant file; otherwise an environment variable of that name. Never a key.
    let switchID: String
    let snapshot: MutationOperator.Snapshot
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32?
    /// From launch to classification, to the millisecond.
    let durationSeconds: Double
    /// 0 is the mutated project, n is its clone `<mutated>_worker<n>`.
    let worker: Int
    let finishedAt: Date
    /// For a killed, crashed or timed-out mutant whose run's failed-test lines are reliable: the tests its log shows
    /// failing, each once, in the order they first failed, at most `FailedTestLine.killedByLimit`. The list is
    /// complete when `endedBy` is `exited` and `failedTestCount` is its length.
    let killedBy: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String?
    /// The kept log's file name in the session's `logDirectory`.
    let log: String
    /// SHA-256 of the mutant's original file.
    let fileSHA256: String?

    var key: MutantKey {
        MutantKey(path: path, mutationOperatorId: mutationOperatorId, line: line, column: column, occurrence: occurrence)
    }
}

extension MutantResult {
    /// The record of `finished`, the run of `schema`'s mutant, tested with `configuration`, the effective one.
    init(
        key: MutantKey,
        schema: MutationSchema,
        finished: FinishedRun,
        configuration: MuterConfiguration,
        session: Int,
        finishedAt: Date,
        log: String,
        fileSHA256: String? = nil
    ) {
        let run = finished.run
        let failures = Self.failedTests(of: run, linesAreReliable: configuration.failedTestLinesAreReliable)
        self.init(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            utf8Offset: schema.position.utf8Offset,
            mutationOperatorId: schema.mutationOperatorId,
            switchID: schema.id,
            snapshot: schema.snapshot,
            outcome: run.outcome,
            endedBy: run.ending,
            exitStatus: run.ending == .exited ? run.exitStatus : nil,
            durationSeconds: (finished.seconds * 1000).rounded() / 1000,
            worker: finished.worker,
            finishedAt: finishedAt,
            killedBy: failures?.tests,
            failedTestCount: failures?.count,
            firstFailedTestLine: failures?.firstLine,
            log: log,
            fileSHA256: fileSHA256
        )
    }

    /// The tests a killed, crashed or timed-out run's log shows failing. nil for any other run, and when the
    /// baseline printed a line shaped like a failed test, as such lines then name no test the mutant failed.
    private static func failedTests(of run: TestRun, linesAreReliable: Bool) -> FailedTestLine.FailedTests? {
        guard linesAreReliable, [.failed, .runtimeError, .timeout].contains(run.outcome) else { return nil }
        return FailedTestLine.failedTests(inLog: run.testLog)
    }
}

/// A session's last line, written when mutation testing stops however it can. A run killed by SIGKILL, or that
/// crashed, has none.
struct ResultsEnd: Codable, Equatable {
    enum Reason: String, Codable {
        case finished
        case aborted
        case interrupted
    }

    var kind = "end"
    let session: Int
    let endedAt: Date
    let reason: Reason
    /// Why it stopped early: the stopping signal's name (`"SIGINT"`) for an interruption a signal caused, or else a
    /// short code (`detail(for:)`).
    let detail: String?
    /// Exactly the session's `MutationTestOutcome.testDuration`.
    let testDurationSeconds: Double
    /// How many mutant lines the session wrote.
    let recorded: Int

    /// A short code for why mutation testing stopped with `error`, never a log: the abort reason's name, the worker
    /// whose baseline failed, or else the error's type. None for a cancellation, which `interrupted` says.
    static func detail(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        guard case let MuterError.mutationTestingAborted(reason) = error else {
            return String(describing: type(of: error))
        }
        switch reason {
        case .baselineTestFailed:
            return "baselineTestFailed"
        case let .workerBaselineTestFailed(worker, _, _):
            return "workerBaselineTestFailed(worker: \(worker))"
        case .tooManyBuildErrors:
            return "tooManyBuildErrors"
        case .unknownError:
            return "unknownError"
        }
    }
}
