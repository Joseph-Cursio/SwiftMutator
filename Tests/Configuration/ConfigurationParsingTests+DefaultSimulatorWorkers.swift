@testable import muterCore
import XCTest

/// The default count of an xcodebuild run that tests on a simulator, which neither `mutationTestWorkers` nor
/// `--workers` gives.
extension ConfigurationParsingTests {
    private static let gibibyte: UInt64 = 1 << 30

    // Half the processors, one worker for each 16 GiB of memory, as each worker's simulator holds some, and at most 2.
    func test_theDefaultWorkerCount_forXcodebuildOnASimulator_goesByTheProcessorsAndTheMemory() {
        let iOS = xcodebuild(testingOn: "platform=iOS Simulator,name=iPhone 17")
        // Processors, GiB of memory, and the count.
        let cases: [[Int]] = [
            [18, 8, 1],
            [18, 16, 1],
            [18, 31, 1],
            [18, 32, 2],
            [18, 64, 2],
            [18, 128, 2],
            [1, 64, 1],
            [2, 64, 1],
            [3, 64, 1],
            [4, 64, 2],
            [4, 32, 2],
        ]

        for machine in cases {
            let processors = machine[0]
            let memory = machine[1]
            let count = machine[2]
            current.processorCount = processors
            current.physicalMemory = UInt64(memory) * Self.gibibyte
            XCTAssertEqual(iOS.defaultWorkerCount, count, "\(processors) processors, \(memory) GiB")
            XCTAssertEqual(iOS.workerCount, count, "\(processors) processors, \(memory) GiB")
        }
    }

    // Every test's world has a Mac of 8 GiB, so an xcodebuild run tests one mutant at a time unless a test says.
    func test_theDefaultWorkerCount_forXcodebuildOnASimulator_isOneInEveryTestsWorld() {
        current.processorCount = 18

        XCTAssertEqual(xcodebuild(testingOn: "platform=iOS Simulator,name=iPhone 17").defaultWorkerCount, 1)
    }

    // Only a simulator can be made for a worker, and only for a destination that names one.
    func test_theDefaultWorkerCount_forXcodebuild_isOneOffASimulator() {
        current.processorCount = 18
        current.physicalMemory = 64 * Self.gibibyte
        let destinations = [
            "platform=macOS",
            "platform=macOS,variant=Mac Catalyst",
            "platform=iOS,id=00008110-000A1C2E3F45801E",
            "generic/platform=iOS Simulator",
        ]

        for destination in destinations {
            XCTAssertEqual(xcodebuild(testingOn: destination).defaultWorkerCount, 1, destination)
            XCTAssertEqual(xcodebuild(testingOn: destination).workerCount(testing: 500), 1, destination)
        }
        let noDestination = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        XCTAssertEqual(noDestination.defaultWorkerCount, 1)
    }

    // False asks for no simulator SwiftMutator makes; true asks for one even for a lone worker.
    func test_theDefaultWorkerCount_forXcodebuild_isOne_withOneWorkerSimulatorFalse() {
        current.processorCount = 18
        current.physicalMemory = 64 * Self.gibibyte
        let destination = "platform=iOS Simulator,name=iPhone 17"

        XCTAssertEqual(xcodebuild(testingOn: destination, oneWorkerSimulator: .disabled).defaultWorkerCount, 1)
        XCTAssertEqual(xcodebuild(testingOn: destination, oneWorkerSimulator: .disabled).workerCount(testing: 500), 1)
        XCTAssertEqual(xcodebuild(testingOn: destination, oneWorkerSimulator: .enabled).defaultWorkerCount, 2)
        XCTAssertEqual(xcodebuild(testingOn: destination, oneWorkerSimulator: .unset).defaultWorkerCount, 2)
    }

    // A count that was asked for is the count, whatever the machine, and the mutants don't need to pay it back.
    func test_anAskedCount_forXcodebuildOnASimulator_isKept() {
        current.processorCount = 18
        current.physicalMemory = 64 * Self.gibibyte
        let destination = "platform=iOS Simulator,name=iPhone 17"

        XCTAssertEqual(xcodebuild(testingOn: destination, workers: 4).workerCount, 4)
        XCTAssertEqual(xcodebuild(testingOn: destination, workers: 4).workerCount(testing: 10), 4)
        XCTAssertEqual(xcodebuild(testingOn: destination, workers: 1).workerCount(testing: 500), 1)
        current.physicalMemory = 8 * Self.gibibyte
        XCTAssertEqual(xcodebuild(testingOn: destination, workers: 3).workerCount(testing: 500), 3)
    }

    // Each simulator past the first costs 15 to 30 s to make, boot and check, which about 50 mutants pay back.
    func test_workerCountTesting_forXcodebuildOnASimulator_goesByTheMutants() {
        current.processorCount = 18
        current.physicalMemory = 64 * Self.gibibyte
        let iOS = xcodebuild(testingOn: "platform=iOS Simulator,name=iPhone 17")

        let byDefault = [0: 0, 1: 1, 2: 1, 49: 1, 50: 2, 99: 2, 100: 2, 5_000: 2]
        for (mutants, count) in byDefault {
            XCTAssertEqual(iOS.workerCount(testing: mutants), count, "\(mutants)")
        }
    }

    /// An xcodebuild test command on `destination`, with no workers asked for and `oneWorkerSimulator` as given.
    private func xcodebuild(
        testingOn destination: String,
        oneWorkerSimulator: ConfigurationSwitch = .unset
    ) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            oneWorkerSimulator: oneWorkerSimulator
        )
    }
}
