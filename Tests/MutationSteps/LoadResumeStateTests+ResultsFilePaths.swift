@testable import muterCore
import TestingExtensions
import XCTest

extension LoadResumeStateTests {
    // Saving the report there would replace every result the resume keeps.
    func test_aReportPathThatIsTheResultsFile_isRefused() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        resume(resultsPath, reportURL: URL(fileURLWithPath: resultsPath))

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.reportWouldReplaceTheResultsFile(resultsPath)],
                beforeTheCopy: true
            )
        )
    }

    // Saving the baseline file at the end would replace it too.
    func test_aBaselineFilePathThatIsTheResultsFile_isRefused() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        state.runOptions = .make(
            mutationOperatorsList: [.ror],
            skipCoverage: true,
            writeBaseline: resultsPath,
            resumeURL: URL(fileURLWithPath: resultsPath)
        )

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.baselineFileWouldReplaceTheResultsFile(resultsPath)],
                beforeTheCopy: true
            )
        )
    }

    // As for -o, naming the flag or the key that asked for it. The key's path is the project's, resolved.
    func test_anOtherReportPathThatIsTheResultsFile_isRefused() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let request = ReportRequest(format: .markdown, path: resultsPath)
        let relative = ReportRequest(format: .json, path: "../project_muter_logs/Oct 6, 2026 at 9:12 AM/results.jsonl")
        state.muterConfiguration = configuration.overriding(workers: nil, timeout: nil, reports: [relative, request])

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [
                    .otherReportWouldReplaceTheResultsFile(relative.resolved(in: project), isTheFlags: false),
                    .otherReportWouldReplaceTheResultsFile(request, isTheFlags: false),
                ],
                beforeTheCopy: true
            )
        )

        state.runOptions = .make(
            reports: [request],
            mutationOperatorsList: [.ror],
            skipCoverage: true,
            resumeURL: URL(fileURLWithPath: resultsPath)
        )
        state.muterConfiguration = configuration.overriding(workers: nil, timeout: nil, reports: [request])
        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.otherReportWouldReplaceTheResultsFile(request, isTheFlags: true)],
                beforeTheCopy: true
            )
        )
    }
}
