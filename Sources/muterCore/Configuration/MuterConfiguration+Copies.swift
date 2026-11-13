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
    /// filter, or for a build system that takes neither (`propertyRerunsUnsupportedReason`).
    func withPropertyTestFilter() -> Self? {
        guard let filter = propertyTestFilter, !filter.isEmpty, propertyRerunsUnsupportedReason == nil else {
            return nil
        }
        var copy = self
        switch buildSystem {
        case .swift:
            copy.testFilterArguments = filter.flatMap { ["--filter", $0] }
            copy.directTestRun = directTestRun?.adding(copy.testFilterArguments)

        case .xcodebuild:
            copy.testFilterArguments = filter.map { "-only-testing:\($0)" }

        case .unknown:
            return nil
        }
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
    /// `failUnder`, `propertyTests` and `reports`, and `--exclude`'s entries after `exclude`'s: a run records and
    /// compares them as it does the keys.
    func overriding(
        workers: Int?,
        timeout: Double?,
        buildTimeout: Double? = nil,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        reports: [ReportRequest]? = nil,
        exclude: [String] = []
    ) -> Self {
        var copy = self
        copy.excludeFileList += exclude
        if let workers { copy.mutationTestWorkers = workers }
        if let timeout { copy.testSuiteTimeout = timeout }
        if let buildTimeout { copy.buildTimeout = buildTimeout }
        if let failUnder { copy.failUnder = failUnder }
        if let propertyTests { copy.propertyTests = propertyTests }
        if let reports { copy.reports = reports }
        return copy
    }

    /// This configuration with `exclude`'s entries sorted, once each, which choose the same files in any order.
    var withExcludesInOrder: Self {
        var copy = self
        copy.excludeFileList = Set(excludeFileList).sorted()
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
