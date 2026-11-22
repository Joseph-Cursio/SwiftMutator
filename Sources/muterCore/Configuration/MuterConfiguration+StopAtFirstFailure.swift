extension MuterConfiguration {
    /// Why a mutant's test run can't be stopped at its first failed test with this test command, or nil: `swift test`'s
    /// can, unless its arguments retry failing tests; an xcodebuild run's only on a simulator
    /// (`xcodebuildStopUnsupportedReason`); no other test command's. It completes "stopAtFirstFailure is off for this
    /// run, so every mutant's tests run to the end: …".
    var stopAtFirstFailureUnsupportedReason: String? {
        switch buildSystem {
        case .swift:
            guard testCommandArguments.contains(where: { $0.hasPrefix("--repeat-until") }) else { return nil }
            return "the test arguments retry failing tests (--repeat-until), so a failure doesn't decide the run"

        case .xcodebuild:
            return xcodebuildStopUnsupportedReason

        case .unknown:
            return "it works only for `swift test`, and for xcodebuild on a simulator (set `buildSystem` if "
                + "`executable` wraps one of them); other test commands run tests where SwiftMutator can't stop them"
        }
    }

    /// Whether mutants' test runs stop at their first failed test, or at a crash: unless `stopAtFirstFailure` is
    /// `disabled`, whenever this test command supports it and failed-test lines are reliable. Baselines never do.
    /// On by default since an A/B run on SwiftProjectLint (255 mutants, 4 workers) took 37% less time and the switch
    /// changed no mutant's verdict. On by default for xcodebuild on a simulator too, since an A/B run on BonMot's iOS
    /// tests (104 mutants, 2 simulator workers) spent 38% less time on mutants and changed no verdict; to make them
    /// opt-in, they would need `stopAtFirstFailure == .enabled` here. A mutant that both fails a test and crashes can
    /// be reported killed by a test failure rather than by a runtime error, depending on which comes first.
    var stopsAtFirstFailure: Bool {
        guard stopAtFirstFailureUnsupportedReason == nil, failedTestLinesAreReliable else { return false }
        return stopAtFirstFailure != .disabled
    }

    /// Why an xcodebuild mutant's run can't stop, or nil when it can: only on a simulator, where killing xcodebuild's
    /// process tree was measured to end the simulator's test process within 0.2 s (`ProcessTree`, #81), which nothing
    /// measured on a Mac or a device. A worker's simulator of its own is one; the test command's first `-destination`
    /// is when it names a simulator's platform, or names one by its `id=` or `name=` alone that simctl lists
    /// (`firstDestinationIsASimulator`), unless the worker on it tests in parallel (`destinationRunsInParallel`): its
    /// runs then test on clones of that simulator, which name a failed test in no line that stops a run, and which the
    /// measurement didn't cover. Before the workers are known, that is left out: a worker on a simulator of its own
    /// tests one test at a time. Never when the test arguments retry failing tests, nor when the run tests a UI test
    /// target, whose app can outlive xcodebuild (`uiTestTargets`). A test plan that retries failing tests isn't seen
    /// here: the `.xctestrun` read doesn't say so. A passing baseline whose test failed and then passed on its retry
    /// still turns stopping off, by its failed-test line.
    private var xcodebuildStopUnsupportedReason: String? {
        if testCommandArguments.contains("-retry-tests-on-failure") {
            return "the test arguments retry failing tests (-retry-tests-on-failure), so a failure doesn't decide the "
                + "run"
        }
        if !uiTestTargets.isEmpty {
            let targets = uiTestTargets.map { "`\($0)`" }.joined(separator: ", ")
            return "the tests include UI tests (\(targets)), whose app can outlive a stopped run; "
                + "`-skip-testing:<target>` in `arguments` leaves a target out"
        }
        if xcodeWorker?.destination != nil {
            return nil
        }
        guard let destination = firstDestination else {
            return "under xcodebuild it works only on a simulator, and the test command gives no `-destination`"
        }
        if let reason = Self.stopUnsupportedReason(on: destination, listedAsASimulator: firstDestinationIsASimulator) {
            return reason
        }
        if let worker = xcodeWorker, !worker.parallelTestingOff, destinationRunsInParallel {
            return "a run on `-destination \(destination)` tests in parallel, on clones of the simulator, whose "
                + "failed tests xcodebuild reports in lines that can't stop it; `-parallel-testing-enabled NO` in "
                + "`arguments` tests one at a time"
        }
        return nil
    }

    /// Why an xcodebuild mutant's run on `destination`, the test command's first `-destination`, can't stop, or nil
    /// when it names a simulator: by its platform, such as `platform=iOS Simulator,name=iPhone 17 Pro`, or by its `id=`
    /// or `name=` alone when `listedAsASimulator` says simctl lists the simulator it names. Not a Mac, Mac Catalyst
    /// included, a device, or a `generic/` destination, which names any device of a platform.
    static func stopUnsupportedReason(on destination: String, listedAsASimulator: Bool) -> String? {
        let named = "`-destination \(destination)`"
        if destination.trimmed.hasPrefix("generic/") {
            return "under xcodebuild it works only on one simulator, and \(named) names any device of a platform"
        }
        if namesAMac(destination) {
            return "under xcodebuild it works only on a simulator, where stopping a run was measured to end its tests, "
                + "and \(named) names a Mac"
        }
        guard let simulator = SimulatorDestination(destination: destination) else {
            return "under xcodebuild it works only on a simulator, which \(named) doesn't name"
        }
        if simulator.platform == nil, !listedAsASimulator {
            return "under xcodebuild it works only on a simulator, and simctl lists none that \(named) names; "
                + "`platform=iOS Simulator`, or the simulator's own platform, says it is one"
        }
        return nil
    }

    /// Those of `targets`, test targets of an `.xctestrun`, such as its UI test targets, that a mutant's xcodebuild run
    /// tests: all but those a `-skip-testing` in the test arguments leaves out whole, and with `-only-testing`, only
    /// those it names, whole or in part. An `-only-testing @file` names tests from a file this doesn't read, so with
    /// one, every target counts.
    func targetsTested(among targets: [String]) -> [String] {
        let skipped = Set(testIdentifiers(givenBy: "-skip-testing"))
        let onlyTesting = testIdentifiers(givenBy: "-only-testing")
        let readsAFile = onlyTesting.contains { $0.hasPrefix("@") }
        let onlyTargets = Set(onlyTesting.map { identifier in String(identifier.prefix { $0 != "/" }) })
        return targets.filter { target in
            !skipped.contains(target) && (onlyTargets.isEmpty || readsAFile || onlyTargets.contains(target))
        }
    }

    /// The test identifiers the test arguments give `option`, `-only-testing` or `-skip-testing`, written either as
    /// `-only-testing:AppTests/SumTests` or as `-only-testing AppTests/SumTests`.
    private func testIdentifiers(givenBy option: String) -> [String] {
        XcodebuildArguments(testCommandArguments).arguments
            .filter { $0.kind == .option && $0.name == option }
            .map { argument in
                let written = argument.written
                return written.count > 1 ? written[1] : String(written[0].dropFirst(option.count + 1))
            }
    }
}
