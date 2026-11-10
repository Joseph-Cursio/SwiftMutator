import Foundation

// A pure-Swift async injection seam (an I/O *dependency*), not an Objective-C delegate, so the
// `class_delegate_protocol` expectation of a `class`/`@objc`-based protocol does not apply here.
// swiftlint:disable:next class_delegate_protocol
protocol MutationTestingIODelegate: Sendable {
    /// Runs the test command with `schemata` switched on. Its output goes to `fileName`, a path relative to the
    /// current directory or an absolute one, whose folder is made if need be. The file stays once its log has been read
    /// back, for the caller to keep or discard (`keepOutput(at:as:)`), so a run that is never recorded, one a stop cut
    /// short or one that finished as a stop or an abort came, leaves it where it is.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)` with the test command run in
    /// `workingDirectory`, a parallel worker's clone of the mutated project. A relative `fileName` is still taken
    /// from the current directory, not `workingDirectory`.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun

    /// A baseline: the whole test command, build included, with no mutant switched on, stopped once it has run for
    /// `buildTimeout` seconds, if that is set, which its ending then says. `fileName` is as in
    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// `benchmarkTests(using:savingResultsIntoFileNamed:)` with the test command, build included, run
    /// in `workingDirectory`, a parallel worker's clone of the mutated project. A relative `fileName` is still taken
    /// from the current directory, not `workingDirectory`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun

    /// A mutant's test command, which skips the build, with no mutant switched on, once the baseline has built the
    /// project: what a mutant's run costs. Never stopped at its first failed test, and stopped only once it has run for
    /// `timeLimit` seconds, if that isn't nil, which its ending then says. An xcodebuild worker's configuration runs it
    /// on that worker, from its `.xctestrun`, so it also checks the worker. `fileName` is as in
    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        timeLimit: TimeInterval?,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// A control run: a mutant's test command, which skips the build, with no mutant switched on, under the mutants'
    /// time limit and never stopped at its first failed test, so its log shows every test that failed. Run among the
    /// mutants, in `workingDirectory`, a worker's folder, or the current directory if nil, under the same load. An
    /// xcodebuild worker's configuration runs it on that worker, from its `.xctestrun`, which must switch no mutant
    /// on. `fileName` is as in `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func runControlTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL?
    ) async -> TestRun

    /// Writes `testRun`, with `schemata`'s mutant switched on, to `fileName` in `path`, the `.xctestrun` an xcodebuild
    /// worker's runs test from. `.null` switches no mutant on, for a run with none.
    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL,
        named fileName: String
    ) async throws

    /// Moves the output file a run wrote, `output`, named as given to `runTestSuite`, to `path`, replacing any file
    /// there, or removes it when `path` is nil. Either path is relative to the current directory or an absolute one.
    /// Only a regular file is moved or removed, never a folder or a symbolic link. Whether the file was moved: false
    /// when there is none, or the move failed, and the output is then removed.
    @discardableResult
    func keepOutput(at output: String, as path: String?) -> Bool
}

extension MutationTestingIODelegate {
    /// `switchOn(schemata:for:at:named:)` to the first worker's `.xctestrun`, `muter.xctestrun`.
    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL
    ) async throws {
        try await switchOn(
            schemata: schemata,
            for: testRun,
            at: path,
            named: MutationTestingDelegate.muterTestRunFileName
        )
    }
}
