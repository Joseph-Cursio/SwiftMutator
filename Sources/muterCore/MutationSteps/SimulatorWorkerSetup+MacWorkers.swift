import Foundation

/// The workers of an xcodebuild run that test on this Mac, with no simulator (`MuterConfiguration.testsOnMacWorkers`).
extension SimulatorWorkerSetup {
    /// Whether the `planned` workers test on this Mac: more than one, with `configuration`'s test command able to
    /// (`MuterConfiguration.testsOnMacWorkers`), and no reason, `unavailable`, why the run is to test one mutant at a
    /// time.
    static func testsOnMacWorkers(_ planned: Int, configuration: MuterConfiguration, unavailable: String?) -> Bool {
        planned > 1 && unavailable == nil && configuration.testsOnMacWorkers
    }

    /// The `count` workers that test on this Mac: each in the mutated project, from the build the baseline made, with
    /// its own `.xctestrun`, `muter.xctestrun` for worker 0 and `muter-worker<n>.xctestrun` for the others, and its
    /// own derived data, on the test command's own `-destination`. Each tests one test at a time, as a simulator's
    /// worker does: with parallel testing on, each of N workers would start its own test processes on the same
    /// processors, which the count, half of them at most, leaves to the workers. Each has a temporary folder of its
    /// own too, as a SwiftPM worker has (`temporaryFolder(of:)`).
    static func macWorkers(_ count: Int, state: AnyMutationTestState) -> [MuterConfiguration.XcodeWorker] {
        (0..<count).map { worker in
            let derivedData = MuterConfiguration.XcodeWorker.derivedData(
                ofWorker: worker,
                in: state.mutatedProjectDirectoryURL
            )
            return MuterConfiguration.XcodeWorker(
                testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: worker),
                derivedData: derivedData,
                testDiagnosticsOff: state.testDiagnosticsCanBeTurnedOff,
                parallelTestingOff: true,
                environment: temporaryFolder(ofWorkerWith: derivedData).environment
            )
        }
    }

    /// The temporary folder of the worker on this Mac whose derived data is `derivedData`, a folder of its own, which
    /// names it, as the workers share the mutated project. Its tests' `EnvironmentVariables` name it
    /// (`MuterConfiguration.XcodeWorker.environment`), so that a test that writes a fixed name in the temporary
    /// directory doesn't fail another worker's. Xcode's `xctest` agent honours `DIRHELPER_USER_DIR_SUFFIX`: run from
    /// an `.xctestrun` that sets it, with `xcodebuild test-without-building` (Xcode 27.2), a test's
    /// `NSTemporaryDirectory()`, `FileManager`'s `temporaryDirectory` and `TMPDIR` were all the folder of that name.
    static func temporaryFolder(ofWorkerWith derivedData: String) -> WorkerTemporaryFolder {
        WorkerTemporaryFolder(
            forWorkerIn: URL(fileURLWithPath: derivedData),
            under: FileManager.default.temporaryDirectory
        )
    }

    /// One worker, on the test command's destination, once `failed`, the run with no mutant on of a worker on this Mac,
    /// didn't pass, with why, which names its log if it `keptLog`. The workers' runs went at once, as their mutants'
    /// would, where tests that write to what they share, `UserDefaults.standard` and the home folder, can fail each
    /// other's, which the reason says of any run but one that never started, as its `.xctestrun` couldn't be written,
    /// whose log says so.
    static func macFallingBack(
        after failed: CheckRun,
        keptLog: Bool,
        configuration: MuterConfiguration
    ) -> Workers {
        let log = keptLog ? " (its log is \(checkRunLogName(ofWorker: failed.worker)))" : ""
        let ended = howItEnded(failed, why: "", buildTimeout: configuration.buildTimeout)
        let shared = failed.output == nil
            ? ""
            : "; the workers' runs share this Mac's `UserDefaults` and your home folder, where tests can fail "
                + "each other's"
        let reason = "worker \(failed.worker)'s run with no mutant on, on this Mac, \(ended)\(log)\(shared)"
        return Workers(count: 1, unavailable: reason, configuration: configuration, xcodeWorkers: [])
    }

    /// How `failed`, a worker's run with no mutant on, ended: past `buildTimeout`, or failing, with `why`, which, when
    /// not empty, starts with its own `: `.
    static func howItEnded(_ failed: CheckRun, why: String, buildTimeout: Double?) -> String {
        failed.timedOut
            ? "didn't end within \(String(format: "%g", buildTimeout ?? 0)) s (buildTimeout)"
            : "didn't pass\(why)"
    }
}
