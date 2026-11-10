@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestingDelegateTests {
    func test_makeProcess_doesNotSetMuterRunningMarker() {
        // The shared factory (used for build-for-testing too) must NOT carry IS_MUTER_RUNNING — on
        // some projects it makes xcodebuild skip writing build-request.json, breaking BuildForTesting.
        // The marker belongs only on the test process (asserted in test_testProcessForSwiftBuild).
        let process = MuterProcessFactory.makeProcess()

        XCTAssertNil(process.environment?[isMuterRunningKey])
    }

    func test_makeProcess_dropsAnInheritedMuterRunningMarker() {
        // SwiftMutator sets the marker on the test process, so when its own suite is the one being
        // mutation tested, this process already has it.
        let previous = ProcessInfo.processInfo.environment[isMuterRunningKey]
        setenv(isMuterRunningKey, isMuterRunningValue, 1)
        defer {
            if let previous {
                setenv(isMuterRunningKey, previous, 1)
            } else {
                unsetenv(isMuterRunningKey)
            }
        }

        let process = MuterProcessFactory.makeProcess()

        XCTAssertNil(process.environment?[isMuterRunningKey])
    }

    // When SwiftMutator's own suite is the one being mutation tested, its tests run with the outer run's
    // active-mutant file named. A process started here must not read that file, or the outer run's mutant
    // would be switched on in it. Checked on the pure function, so this test never sets a variable the
    // outer run's generated code may read at any moment.
    func test_inheritedEnvironment_dropsAnOuterRunsActiveMutantFile() {
        let environment = MuterProcessFactory.environment(inheriting: [
            activeMutantFileKey: "/outer/.swiftmutator-active-mutant",
            isMuterRunningKey: isMuterRunningValue,
            "PATH": "/usr/bin",
        ])

        XCTAssertEqual(environment, ["PATH": "/usr/bin"])
    }

    // `swift test` relays its test runners' output through its own standard output, which holds output
    // bound for a file 4 KiB at a time until it exits. A run stopped at its first failed test would show
    // that failure late, or lose its whole log.
    func test_whenStoppingAtFirstFailure_thenEveryTestProcessWritesUnbuffered() throws {
        current.process = { Self.makeProcess(inheritingUnbufferedOutput: nil) }
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            stopAtFirstFailure: true
        )
        let mutant = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        // The baseline too, although it is never stopped, so it runs as the mutants that stop do.
        for schemata in [mutant, .null] {
            let testProcess = try sut.testProcess(
                with: configuration,
                schemata: schemata,
                and: FileHandle(fileDescriptor: 0)
            )

            XCTAssertEqual(testProcess.environment?["NSUnbufferedIO"], "YES", schemata.id)
        }
    }

    func test_whenNotStoppingAtFirstFailure_thenOutputBufferingIsLeftAlone() throws {
        let configurations = [
            MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], stopAtFirstFailure: false),
            // Switched on, but xcodebuild runs can't be stopped.
            MuterConfiguration(executable: "/tmp/xcodebuild", arguments: ["test"], stopAtFirstFailure: true),
        ]
        let mutant = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        for inherited in [nil, "NO"] {
            current.process = { Self.makeProcess(inheritingUnbufferedOutput: inherited) }
            for configuration in configurations {
                for schemata in [mutant, .null] {
                    let testProcess = try sut.testProcess(
                        with: configuration,
                        schemata: schemata,
                        and: FileHandle(fileDescriptor: 0)
                    )

                    XCTAssertEqual(
                        testProcess.environment?["NSUnbufferedIO"],
                        inherited,
                        "\(configuration.testCommandExecutable) \(schemata.id)"
                    )
                }
            }
        }
    }

    /// The real factory's process, as if this process's environment had `NSUnbufferedIO` set to `value`,
    /// so these tests don't depend on the environment the test suite was launched with.
    private static func makeProcess(inheritingUnbufferedOutput value: String?) -> MuterProcess {
        let process = MuterProcessFactory.makeProcess()
        process.environment?["NSUnbufferedIO"] = value
        return process
    }
}
