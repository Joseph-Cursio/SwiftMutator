@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestingDelegateTests {
    // SwiftPM keys its cache of compiled package manifests on the whole environment, names and values, so a
    // variable of each mutant's own made every run recompile every manifest. A worker's runs, its baseline
    // included, get one environment, whether or not they stop at their first failed test.
    func test_swiftTest_baselineAndEveryMutantGetTheSameEnvironment() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let mutantA = try MutationSchema.make(filePath: "/path/Sample.swift", position: .init(line: 1))
        let mutantB = try MutationSchema.make(filePath: "/path/Other.swift", position: .init(line: 2))

        for stopAtFirstFailure in [false, true] {
            let configuration = MuterConfiguration(
                executable: "/tmp/swift",
                arguments: ["test"],
                stopAtFirstFailure: stopAtFirstFailure
            )
            for folder in [nil, URL(fileURLWithPath: "/runs/p_mutated_worker1")] {
                var environments: [[String: String]] = []
                for schemata in [MutationSchema.null, mutantA, mutantB] {
                    let testProcess = try await sut.testProcess(
                        with: configuration,
                        schemata: schemata,
                        and: FileHandle(fileDescriptor: 0),
                        workingDirectory: folder
                    )
                    environments.append(try XCTUnwrap(testProcess.environment))
                }

                let description = "stopAtFirstFailure: \(stopAtFirstFailure), folder: \(folder?.path ?? "none")"
                XCTAssertEqual(variablesThatDiffer(in: environments), [], description)
                for mutant in [mutantA, mutantB] {
                    XCTAssertEqual(environments.flatMap(\.keys).filter { $0.contains(mutant.id) }, [], description)
                }
                if stopAtFirstFailure {
                    XCTAssertEqual(environments[0][unbufferedOutputKey], unbufferedOutputValue, description)
                }
            }
        }
    }

    /// The names of the variables whose values differ between `environments`, or that only some of them set.
    /// Only the names, so a failure doesn't print the values this suite inherited.
    private func variablesThatDiffer(in environments: [[String: String]]) -> [String] {
        Set(environments.flatMap(\.keys))
            .filter { name in environments.contains { $0[name] != environments.first?[name] } }
            .sorted()
    }

    // A baseline names the file too, empty, so tests that can't read it fail the baseline rather than let every
    // mutant survive.
    func test_swiftTest_aBaselineNamesNoMutant() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])

        let testProcess = try await sut.testProcess(
            with: configuration,
            schemata: .null,
            and: FileHandle(fileDescriptor: 0)
        )

        let activeMutantFile = "\(outputFolder)\(activeMutantFileSuffix)"
        XCTAssertEqual(writeFile.contentPassed, "")
        XCTAssertEqual(writeFile.pathPassed, activeMutantFile)
        XCTAssertEqual(testProcess.environment?[activeMutantFileKey], activeMutantFile)
    }

    // Workers test mutants at once, each in its own folder, so each names its mutant in a file of its own.
    func test_swiftTest_eachWorkerHasItsOwnActiveMutantFile() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        for folder in ["/runs/p_mutated", "/runs/p_mutated_worker1"] {
            let testProcess = try await sut.testProcess(
                with: configuration,
                schemata: schemata,
                and: FileHandle(fileDescriptor: 0),
                workingDirectory: URL(fileURLWithPath: folder)
            )

            let activeMutantFile = "\(folder)\(activeMutantFileSuffix)"
            XCTAssertEqual(writeFile.contentPassed?.components(separatedBy: "\n").first, schemata.id, folder)
            XCTAssertEqual(writeFile.pathPassed, activeMutantFile, folder)
            XCTAssertEqual(testProcess.environment?[activeMutantFileKey], activeMutantFile, folder)
        }
    }

    // A worker's folder is a whole copy of the project, `.git` included, so a test that lists the package's hidden
    // files, or needs a clean `git status`, would see a file written in it.
    func test_swiftTest_theActiveMutantFileIsBesideTheWorkersFolder_neverInIt() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])

        for folder in [nil, URL(fileURLWithPath: "/runs/p_mutated_worker1")] {
            _ = try await sut.testProcess(
                with: configuration,
                schemata: .null,
                and: FileHandle(fileDescriptor: 0),
                workingDirectory: folder
            )

            let workersFolder = folder ?? outputFolderURL
            let written = try XCTUnwrap(writeFile.pathPassed)
            XCTAssertFalse(written.hasPrefix(workersFolder.path + "/"), written)
            XCTAssertEqual(
                URL(fileURLWithPath: written).deletingLastPathComponent().path,
                workersFolder.deletingLastPathComponent().path
            )
        }
    }

    // A wrapper script counts as `swift test` with `buildSystem: swift`, and its runs switch mutants on as it does.
    func test_aWrapperDeclaredSwiftUsesTheActiveMutantFile() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(
            executable: "/tmp/run-tests.sh",
            arguments: ["test"],
            buildSystem: .swift
        )
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        let testProcess = try await sut.testProcess(
            with: configuration,
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        let activeMutantFile = "\(outputFolder)\(activeMutantFileSuffix)"
        XCTAssertEqual(writeFile.contentPassed?.components(separatedBy: "\n").first, schemata.id)
        XCTAssertEqual(writeFile.pathPassed, activeMutantFile)
        XCTAssertEqual(testProcess.environment?[activeMutantFileKey], activeMutantFile)
        XCTAssertNil(testProcess.environment?[schemata.id])
    }

    // SwiftMutator can't tell whether a wrapper's tests can read a file on this machine: it may run them in
    // Docker or over ssh. xcodebuild passes variables on to a simulator's test host.
    func test_otherTestCommands_stillSwitchTheMutantOnThroughItsOwnVariable() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        for executable in ["/tmp/xcodebuild", "/tmp/run-tests.sh"] {
            let configuration = MuterConfiguration(executable: executable, arguments: ["test"])

            let testProcess = try await sut.testProcess(
                with: configuration,
                schemata: schemata,
                and: FileHandle(fileDescriptor: 0)
            )
            let baselineProcess = try await sut.testProcess(
                with: configuration,
                schemata: .null,
                and: FileHandle(fileDescriptor: 0)
            )

            XCTAssertEqual(testProcess.environment?[schemata.id], "YES", executable)
            // Also forwarded with the SIMCTL_CHILD_ prefix so it reaches an iOS Simulator test host
            // (CoreSimulator only propagates SIMCTL_CHILD_-prefixed vars into the simulated process).
            XCTAssertEqual(testProcess.environment?["SIMCTL_CHILD_\(schemata.id)"], "YES", executable)
            XCTAssertNil(testProcess.environment?[activeMutantFileKey], executable)
            XCTAssertNil(baselineProcess.environment?[activeMutantFileKey], executable)
        }
        XCTAssertFalse(writeFile.writeFileCalled)
    }

    // The tests would otherwise run with whatever mutant the file named before, or with none switched on.
    func test_whenTheActiveMutantFileCannotBeWritten_thenTheTestCommandIsNotRun() async throws {
        let error = CocoaError(.fileWriteNoPermission)
        writeFile.errorToThrow = error

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"]),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .buildError)
        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertFalse(process.runCalled)
        XCTAssertTrue(result.testLog.contains(error.localizedDescription), result.testLog)
    }

    // The test bundles run directly, through `/bin/sh`, read the mutant from the same file as `swift test` does:
    // the script inherits the variable that names it, and adds only its own.
    func test_whenTheTestBundlesRunDirectly_theMutantIsStillSwitchedOnThroughTheActiveMutantFile() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        let testProcess = try await sut.testProcess(
            with: directRunConfiguration(),
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        let activeMutantFile = "\(outputFolder)\(activeMutantFileSuffix)"
        XCTAssertEqual(testProcess.executableURL?.path, "/bin/sh")
        XCTAssertEqual(testProcess.environment?[activeMutantFileKey], activeMutantFile)
        XCTAssertEqual(writeFile.contentPassed?.components(separatedBy: "\n").first, schemata.id)
        XCTAssertEqual(writeFile.pathPassed, activeMutantFile)
        let script = try XCTUnwrap(testProcess.arguments?.last)
        XCTAssertFalse(script.contains(activeMutantFileKey), script)
    }

    // As through `swift test`: a run whose mutant couldn't be named is never a verdict.
    func test_whenTheTestBundlesRunDirectly_andTheActiveMutantFileCannotBeWritten_thenTheyAreNotRun() async throws {
        writeFile.errorToThrow = CocoaError(.fileWriteNoPermission)

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: directRunConfiguration(),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .buildError)
        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertFalse(process.runCalled)
    }

    /// A `swift test` configuration whose mutants run the test bundles directly.
    private func directRunConfiguration() -> MuterConfiguration {
        MuterConfiguration(executable: "/tmp/swift", arguments: ["test"]).withDirectTestRun(DirectTestRun(
            helper: "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
            productsFolder: ".build/out/Products/Debug",
            bundles: ["CoreTests"],
            testFiles: [:],
            platformDeveloperFolder: "/Platforms/MacOSX.platform/Developer",
            arguments: ["--skip-build"]
        ))
    }
}
