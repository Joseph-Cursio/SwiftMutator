import Foundation
@testable import muterCore
import SwiftParser
import SwiftSyntax

extension Run.Options {
    static func make(
        filesToMutate: [String] = [],
        exclude: [String] = [],
        since: String? = nil,
        changedLinesOnly: Bool = false,
        shard: Shard? = nil,
        sample: Sample? = nil,
        reportFormat: ReportFormat = .plain,
        reportURL: URL? = nil,
        reports: [ReportRequest]? = nil,
        mutationOperatorsList: MutationOperatorList = [],
        skipCoverage: Bool = false,
        skipUpdateCheck: Bool = false,
        verbose: Bool = false,
        configurationURL: URL? = nil,
        testPlanURL: URL? = nil,
        workers: Int? = nil,
        timeout: Double? = nil,
        buildTimeout: Double? = nil,
        failUnder: Double? = nil,
        baseline: String? = nil,
        maxNewSurvivors: Int? = nil,
        maxScoreDrop: Double? = nil,
        maxDoubtfulKills: Int? = nil,
        writeBaseline: String? = nil,
        createTestPlan: Bool = false,
        resumeURL: URL? = nil,
        reuseURL: URL? = nil,
        resumeIgnoring: [String] = [],
        forceResume: Bool = false,
        planIgnoring: [String] = [],
        mutant: MutantReference? = nil
    ) -> Self {
        .init(
            skipCoverage: skipCoverage,
            skipUpdateCheck: skipUpdateCheck,
            configurationURL: configurationURL,
            filesToMutate: filesToMutate,
            exclude: exclude,
            since: since,
            changedLinesOnly: changedLinesOnly,
            shard: shard,
            sample: sample,
            reportFormat: reportFormat,
            reportURL: reportURL,
            reports: reports,
            mutationOperatorsList: mutationOperatorsList,
            verbose: verbose,
            testPlanURL: testPlanURL,
            workers: workers,
            timeout: timeout,
            buildTimeout: buildTimeout,
            failUnder: failUnder,
            baseline: baseline,
            maxNewSurvivors: maxNewSurvivors,
            maxScoreDrop: maxScoreDrop,
            maxDoubtfulKills: maxDoubtfulKills,
            writeBaseline: writeBaseline,
            createTestPlan: createTestPlan,
            resumeURL: resumeURL,
            reuseURL: reuseURL,
            resumeIgnoring: resumeIgnoring,
            forceResume: forceResume,
            planIgnoring: planIgnoring,
            mutant: mutant
        )
    }
}

/// The fixture at `path`, read and parsed. Every test that reads one expects it to be there.
func fixtureSource(at path: String) -> SourceCodeInfo {
    guard let source = muterCore.sourceCode(fromFileAt: path) else {
        fatalError("Unable to read the fixture at \(path)")
    }
    return source
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
/// field is set here, which then reaches the copy tests and `test_everyConfigurationKeyButSeven_isCompared`.
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
        workersShareBuild: .disabled,
        stopAtFirstFailure: .disabled,
        buildTimeout: 600,
        oneWorkerSimulator: .enabled,
        suspectTestFilePercent: 30,
        suspectTestMinimumFiles: 5,
        controlRunEvery: 50,
        suspectKillReruns: 25,
        keepAllLogs: .enabled,
        keepLogFolders: 3,
        keepSwiftLintPhases: .enabled,
        failUnder: 80,
        propertyTests: ["*Properties*"],
        propertyTestFilter: ["Properties"],
        operators: [.ror, .swapTernary],
        skipOperators: [.swapTernary],
        reports: [ReportRequest(format: .markdown, path: "summary.md")]
    )
    .withDirectTestRun(DirectTestRun(
        helper: "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
        productsFolder: ".build/out/Products/Debug",
        bundles: ["CoreTests"],
        testFiles: [:],
        platformDeveloperFolder: "/Platforms/MacOSX.platform/Developer",
        arguments: ["--skip-build"]
    ))
    .forXcodeWorker(MuterConfiguration.XcodeWorker(
        testRunFile: "muter-worker2.xctestrun",
        derivedData: "/path/to/project_mutated_worker2.DerivedData",
        testDiagnosticsOff: true,
        destination: "platform=iOS Simulator,id=8C5A2F0E-1B2C-4D3E-9F40-5A6B7C8D9E0F",
        parallelTestingOff: true
    ))
    // So `testFilterArguments` is set too, as for a property rerun's runs.
    .withPropertyTestFilter() ?? MuterConfiguration()
    let goingToItsEnd = configuration.goingToEachRunsEnd()
    return failedTestLinesAreReliable
        ? goingToItsEnd : goingToItsEnd.withUnreliableFailedTestLines(printedIn: [failedTestLookalikeLog])
}

/// A passing baseline's log with a line shaped like a failed test, which the test printed itself.
let failedTestLookalikeLog = "✘ Test parsesAFailure() recorded an issue at ParserTests.swift:4:5: printed by the test"

extension muterCore.XCTestRun {
    /// An `.xctestrun` in a test plan's format whose one test target has parallel testing on.
    static var parallelizing: muterCore.XCTestRun {
        let testTarget: [String: AnyHashable] = ["ParallelizationEnabled": true]
        let testConfiguration: [String: AnyHashable] = ["TestTargets": [testTarget]]
        return muterCore.XCTestRun(["TestConfigurations": [testConfiguration]])
    }
}
