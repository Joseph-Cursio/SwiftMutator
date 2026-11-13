import Foundation

extension MuterConfiguration {
    /// What one worker's xcodebuild mutant runs test from and write to, beyond the test command's own arguments.
    struct XcodeWorker: Sendable, Equatable {
        /// The `.xctestrun` file, at the mutated project's root, that the worker's runs test from.
        let testRunFile: String
        /// The worker's derived data folder, beside the mutated project (see `derivedData(ofWorker:in:)`). Without it,
        /// every run made a folder of its own in `~/Library/Developer/Xcode/DerivedData`: 3-67 MB each.
        let derivedData: String
        /// The `-destination` the worker's runs test on; nil for the test command's first.
        let destination: String?
        /// Whether the worker's runs test one test at a time, in one test process.
        let parallelTestingOff: Bool
        /// Whether the worker's runs pass `-collect-test-diagnostics never`, so a failing run doesn't spend seconds
        /// collecting diagnostics no one reads. Only when the xcodebuild in use lists the option in its `-help`: one
        /// that doesn't know it would fail every run.
        let testDiagnosticsOff: Bool

        init(
            testRunFile: String,
            derivedData: String,
            testDiagnosticsOff: Bool,
            destination: String? = nil,
            parallelTestingOff: Bool = false
        ) {
            self.testRunFile = testRunFile
            self.derivedData = derivedData
            self.destination = destination
            self.parallelTestingOff = parallelTestingOff
            self.testDiagnosticsOff = testDiagnosticsOff
        }

        /// Worker `worker`'s derived data folder, beside the mutated project, so neither the copy's fingerprint nor the
        /// build it tests from sees it: `<stem>.DerivedData.noindex` for worker 0, and
        /// `<stem>_worker<n>.DerivedData.noindex` for worker n (`MutatedProjectNames.derivedData(ofWorker:in:)`).
        static func derivedData(ofWorker worker: Int, in mutatedProject: URL) -> String {
            MutatedProjectNames.derivedData(ofWorker: worker, in: mutatedProject).path
        }

        /// The arguments the worker's runs add to the test command's.
        var arguments: [String] {
            ["-derivedDataPath", derivedData]
                + (testDiagnosticsOff ? ["-collect-test-diagnostics", "never"] : [])
                + (parallelTestingOff ? ["-parallel-testing-enabled", "NO"] : [])
        }
    }
}
