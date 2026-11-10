@testable import muterCore
import TestingExtensions
import XCTest

final class RunsToTheirEndTests: MuterTestCase {
    private let sut = MutationTestingDelegate()

    // A kill tested again alone goes to its end, in the environment of the first runs: a change to it recompiles
    // the package's manifest, and without unbuffered output a run that hits its time limit loses the failed-test lines
    // it has printed.
    func test_goingToEachRunsEnd_keepsTheEnvironment_ofARunThatStops() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let mutant = try MutationSchema.make(filePath: "/path/Sample.swift", position: .init(line: 1))
        let stops = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])

        var environments: [[String: String]] = []
        for configuration in [stops, stops.goingToEachRunsEnd()] {
            let testProcess = try sut.testProcess(
                with: configuration,
                schemata: mutant,
                and: FileHandle(fileDescriptor: 0),
                workingDirectory: nil
            )
            try environments.append(XCTUnwrap(testProcess.environment))
        }

        XCTAssertEqual(environments.first, environments.last)
        XCTAssertEqual(environments.last?[unbufferedOutputKey], unbufferedOutputValue)
    }
}
