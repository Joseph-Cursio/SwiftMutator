import Foundation

let isMuterRunningKey = "IS_MUTER_RUNNING"
let isMuterRunningValue = "YES"
/// Foundation's switch for unbuffered standard output, which makes `swift test` pass its test runners'
/// output on to the log as it arrives.
let unbufferedOutputKey = "NSUnbufferedIO"
let unbufferedOutputValue = "YES"
/// Names the file holding the ID of the mutant a `swift test` run switches on (empty: none). Its value is the same
/// for every run in a worker's folder: SwiftPM keys its manifest cache on the whole environment, names and values.
let activeMutantFileKey = "SWIFTMUTATOR_ACTIVE_MUTANT_FILE"
/// Names the file the generated code creates once a mutant's block runs (`ActivationMarker`). A `swift test` run gets
/// it on the active-mutant file's second line, so its environment stays the same; any other test command, whose runs
/// each set a variable for their mutant anyway, gets it in the environment.
let activationMarkerKey = "SWIFTMUTATOR_ACTIVATION_MARKER"

enum MuterProcessFactory {
    static func makeProcess() -> MuterProcess {
        let process = Foundation.Process()
        process.qualityOfService = .userInteractive
        process.environment = environment(inheriting: ProcessInfo.processInfo.environment)
        return process
    }

    /// Preserve the parent environment (PATH, DEVELOPER_DIR, …). Do NOT set IS_MUTER_RUNNING here:
    /// this factory also builds the `build-for-testing` process, and on some projects that extra
    /// env var makes xcodebuild skip writing `build-request.json`, breaking BuildForTesting's parse.
    /// Nothing reads IS_MUTER_RUNNING at build time; it's set on the test process (and xctestrun)
    /// where schemata activation lives — see MutationTestingIODelegate.testProcess.
    /// An inherited marker is removed too: SwiftMutator runs with it set when its own test suite is
    /// the one being mutation tested, and it must not reach the build process then either.
    /// An inherited active-mutant file and activation marker are removed too, for the same reason as the marker.
    /// A pure function, so tests never `setenv` a variable the outer run's generated code may read at any moment.
    static func environment(inheriting inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment[isMuterRunningKey] = nil
        environment[activeMutantFileKey] = nil
        environment[activationMarkerKey] = nil
        return environment
    }
}
