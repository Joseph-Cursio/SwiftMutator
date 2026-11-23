import Foundation

extension MuterConfiguration {
    /// A copy of this configuration whose test command runs `executable`.
    func withExecutable(_ executable: String) -> MuterConfiguration {
        var copy = self
        copy.testCommandExecutable = executable
        return copy
    }
}

extension MuterConfiguration {
    /// This configuration with `workedOut` true: what `init` would write, for a run with no configuration file.
    func workedOutFromTheProject() -> Self {
        var copy = self
        copy.workedOut = true
        return copy
    }

    /// This configuration with a mutant's run going to its end, past its first failed test (`runsGoToTheirEnd`).
    func goingToEachRunsEnd() -> Self {
        var copy = self
        copy.runsGoToTheirEnd = true
        return copy
    }

    /// This configuration with `failedTestLinesAreReliable` false, and the tests that the passing runs' `testLogs`
    /// show failing added to `failedTestLookalikes`.
    func withUnreliableFailedTestLines(printedIn testLogs: [String] = []) -> Self {
        var copy = self
        copy.failedTestLinesAreReliable = false
        for testLog in testLogs {
            copy.failedTestLookalikes.formUnion(FailedTestLine.failedTestIdentities(inLog: testLog))
        }
        return copy
    }

    /// This configuration with `stopAtFirstFailure` false, so a mutant's test run goes on after its first failed test.
    func withoutStoppingAtFirstFailure() -> Self {
        var copy = self
        copy.stopAtFirstFailure = .disabled
        return copy
    }

    /// This configuration with mutants' test runs starting the test bundles as `directTestRun` says.
    func withDirectTestRun(_ directTestRun: DirectTestRun) -> Self {
        var copy = self
        copy.directTestRun = directTestRun
        return copy
    }

    /// This configuration with its runs testing only what `propertyTestFilter` selects: `swift test`, and the test
    /// bundles run directly, with `--filter` for each entry, and xcodebuild with `-only-testing:`. nil without a
    /// filter, or for a build system that takes neither (`propertyRerunsUnsupportedReason`). Bundles run directly
    /// with XCTest tests run through `swift test` instead (`DirectTestRun.filtered(by:)`).
    func withPropertyTestFilter() -> Self? {
        guard let filter = propertyTestFilter, !filter.isEmpty, propertyRerunsUnsupportedReason == nil else {
            return nil
        }
        var copy = self
        switch buildSystem {
        case .swift:
            copy.testFilterArguments = filter.flatMap { ["--filter", $0] }
            copy.directTestRun = directTestRun?.filtered(by: copy.testFilterArguments)

        case .xcodebuild:
            copy.testFilterArguments = filter.map { "-only-testing:\($0)" }

        case .unknown:
            return nil
        }
        return copy
    }

    /// This configuration with its runs testing everything but what `propertyTestFilter` selects: `swift test`, and the
    /// test bundles run directly, with `--skip` for each entry, as `withPropertyTestFilter()` has them. nil without a
    /// filter, or for any other build system: an xcodebuild run that stopped at its first failed test leaves a list cut
    /// short that this doesn't settle.
    func withPropertyTestsSkipped() -> Self? {
        guard let filter = propertyTestFilter, !filter.isEmpty, propertyRerunsUnsupportedReason == nil,
              buildSystem == .swift
        else { return nil }
        var copy = self
        copy.testFilterArguments = filter.flatMap { ["--skip", $0] }
        copy.directTestRun = directTestRun?.filtered(by: copy.testFilterArguments)
        return copy
    }

    /// Whether the property and example reruns leave the bundles run directly for `swift test`, as a run of XCTest
    /// tests does with a test filter (`withPropertyTestFilter()`). `swift test` then runs in each worker's folder, so
    /// workers can't share one build.
    var propertyRerunsLeaveDirectRuns: Bool {
        directTestRun?.runsXCTest == true && withPropertyTestFilter() != nil
    }

    /// This configuration with the facts that decide whether an xcodebuild mutant's run can stop at its first failed
    /// test, and that aren't configuration keys: whether simctl lists the first `-destination`'s simulator, the UI
    /// test targets the run tests, and whether a run on the test command's destination tests in parallel.
    func withStopFacts(
        firstDestinationIsASimulator: Bool,
        uiTestTargets: [String],
        destinationRunsInParallel: Bool = false
    ) -> Self {
        var copy = self
        copy.firstDestinationIsASimulator = firstDestinationIsASimulator
        copy.uiTestTargets = uiTestTargets
        copy.destinationRunsInParallel = destinationRunsInParallel
        return copy
    }

    /// This configuration with an xcodebuild mutant's runs testing as `worker` says.
    func forXcodeWorker(_ worker: XcodeWorker) -> Self {
        var copy = self
        copy.xcodeWorker = worker
        return copy
    }

    /// This configuration with `--workers`', `--timeout`'s, `--build-timeout`'s, `--fail-under`'s, `--property-tests`'
    /// and `--report`'s values, when given, in place of `mutationTestWorkers`, `mutationTestTimeout`, `buildTimeout`,
    /// `failUnder`, `propertyTests` and `reports`, `gates`, when given, in place of its own, as the gate keys with the
    /// gate flags in (`RunGates.overridden(by:in:)`), `--exclude`'s entries after `exclude`'s, and the other keys'
    /// flags, `keys` (`withKeyFlags(_:)`): a run records and compares them as it does the keys.
    func overriding(
        workers: Int?,
        timeout: Double?,
        buildTimeout: Double? = nil,
        failUnder: Double? = nil,
        gates: RunGates? = nil,
        propertyTests: [String]? = nil,
        reports: [ReportRequest]? = nil,
        exclude: [String] = [],
        keys: KeyFlags = KeyFlags()
    ) -> Self {
        var copy = withKeyFlags(keys)
        copy.excludeFileList += exclude
        if let workers { copy.mutationTestWorkers = workers }
        if let timeout { copy.testSuiteTimeout = timeout }
        if let buildTimeout { copy.buildTimeout = buildTimeout }
        if let failUnder { copy.failUnder = failUnder }
        if let gates { copy.gates = gates }
        if let propertyTests { copy.propertyTests = propertyTests }
        if let reports { copy.reports = reports }
        return copy
    }

    /// This configuration with `exclude`'s and `excludeCalls`' entries sorted, once each, which choose the same files
    /// and calls in any order.
    var withExcludesInOrder: Self {
        var copy = self
        copy.excludeFileList = Set(excludeFileList).sorted()
        copy.excludeCallList = Set(excludeCallList).sorted()
        return copy
    }

    /// This configuration with `testSuiteTimeout` set to `timeout`, unless it already has one.
    func withDefaultTestSuiteTimeout(_ timeout: TimeInterval) -> Self {
        guard testSuiteTimeout == nil else { return self }
        var copy = self
        copy.testSuiteTimeout = timeout
        return copy
    }
}
