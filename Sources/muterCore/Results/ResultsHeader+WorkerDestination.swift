extension ResultsHeader {
    /// Where an xcodebuild session's workers tested its mutants, which the header's `workersOnOwnSimulators` holds as
    /// `true`, `false`, or no key (`AbsentOrBool`).
    enum WorkerDestination: AbsentOrBool {
        /// Each worker on a simulator of its own, which SwiftMutator made: always with more than one worker, and with
        /// one when its simulator passed its run with no mutant on.
        case ownSimulators
        /// On the test command's own `-destination`: one worker, or, on a Mac whose tests run in Xcode's `xctest`
        /// agent, any number (`MuterConfiguration.testsOnMacWorkers`).
        case testCommandsDestination
        /// Not an xcodebuild session, or one with nothing left to test, or one an older SwiftMutator wrote.
        case notRecorded

        static var whenTrue: Self { .ownSimulators }
        static var whenFalse: Self { .testCommandsDestination }
        static var whenAbsent: Self { .notRecorded }

        /// Where `pool` tests an xcodebuild session's `mutants`, `notRecorded` for any other build system's, or when
        /// it tests none, with no worker or nothing to test: on simulators of their own when the run made them
        /// (`SimulatorWorkerSetup.Workers.onOwnSimulators`), as `WorkerChoice` says too, not workers on this Mac.
        init(of pool: SimulatorWorkerSetup.Workers, testing mutants: Int) {
            guard pool.configuration.buildSystem == .xcodebuild, min(pool.count, mutants) > 0 else {
                self = .notRecorded
                return
            }
            self = pool.onOwnSimulators ? .ownSimulators : .testCommandsDestination
        }
    }
}
