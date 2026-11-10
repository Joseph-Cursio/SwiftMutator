@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    // The baseline still builds the project, and makes a kill mean something. Neither the run of the bundles without
    // `swift test` nor a timed run would save more than it costs for one mutant, whose tests all run, so its log names
    // every one that fails. The active-mutant file goes, so the kept copy is left with the mutant off.
    func test_aOneMutantRun_runsTheBaselineAndOneJob_withoutTheProbeOrTimedRun_withStoppingOff() async throws {
        let key = MutantKey(
            path: "/tmp/project/file.swift", mutationOperatorId: .ror, line: 0, column: 0, occurrence: 0
        )
        state.mutationMapping = try [makeSchemataMapping()]
        state.apply([.mutantSelected(key)])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: .enabled
        )
        state.loggingDirectory = "/logs"
        current.directTestRun = { _, _ in
            XCTFail("one mutant's run doesn't try the bundles without swift test")
            return .failure(.init(reason: nil))
        }
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(fileManager.paths.filter { $0.hasSuffix(".active-mutant") }, ["/project_mutated.active-mutant"])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.mutant, key.description)
        XCTAssertNil(header.testRunSeconds)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumDefaultTimeout)
        XCTAssertFalse(header.stopsAtFirstFailure)
        XCTAssertEqual(header.workers, 1)
        // As loaded, which is what a resume compares.
        XCTAssertEqual(header.configuration.stopAtFirstFailure, .enabled)
        let outcome = try XCTUnwrap(finished().first?.object as? MutationTestOutcome)
        XCTAssertEqual(outcome.mutant, key.description)
    }

    // What the end of a run of one mutant prints of it, sent once its line is written: its change, read from the
    // original file and never the copy, its log, its verdict, and what runs its tests with it on.
    func test_aOneMutantRun_sendsWhatItFound_withItsChangeFromTheOriginalFile() async throws {
        let key = try selectOneTernary()
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        ioDelegate.mutantTestLogs = ["Test run with 3 tests passed.\n"]
        let sent = recordEvents(named: [.oneMutantTested])
        var keptWhenSent: [String] = []
        let observer = runEvents.observe(.oneMutantTested) { [fileManager] _ in
            keptWhenSent = Array(fileManager.createdFiles.keys)
        }
        addTeardownBlock { observer.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsAtPath, ["/project/Sources/Bar.swift", "/project/muter.triage.yml"])
        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(run.key, key)
        XCTAssertEqual(run.switchID, state.mutationMapping.first?.mutationSchemata.first?.id)
        XCTAssertEqual(run.change, ["-2:     return flag ? 1 : 2", "+2:     return flag ? 2 : 1"])
        XCTAssertEqual(run.outcome, .passed)
        XCTAssertNil(run.killingTests)
        XCTAssertEqual(run.timeoutSeconds, 60)
        XCTAssertEqual(run.testLog, "Test run with 3 tests passed.\n")
        XCTAssertEqual(run.logPath, "/logs/" + MutationTestLog.keptFileName(for: key))
        XCTAssertTrue(keptWhenSent.contains("/logs/" + MutationTestLog.keptFileName(for: key)), "\(keptWhenSent)")
        XCTAssertEqual(run.mutatedProject, "/project_mutated")
        XCTAssertEqual(run.buildSystem, .swift)
        XCTAssertEqual(run.testCommand, ["/usr/bin/swift", "test"])
    }

    // `--mutant` keeps its log, which the console names, even for a kill by a test its line names.
    func test_aOneMutantRun_ofAKillByANamedTest_keepsItsLog() async throws {
        let key = try selectOneTernary()
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let killing = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        ioDelegate.mutantTestLogs = [killing]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(run.outcome, .failed)
        XCTAssertEqual(run.logPath, "/logs/" + MutationTestLog.keptFileName(for: key))
        XCTAssertEqual(fileManager.createdFiles["/logs/" + MutationTestLog.keptFileName(for: key)], Data(killing.utf8))
        let record = try XCTUnwrap(resultsFiles.records(MutantResult.self).first)
        XCTAssertEqual(record.killedBy?.map(\.name), ["sum()"])
        XCTAssertEqual(record.log, MutationTestLog.keptFileName(for: key))
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.formatVersion)
    }

    // A test plan's file that changed since the plan was made, let through by --plan-ignoring, may no longer hold the
    // mutant's code at its place, so the change is the one the snapshot gives.
    func test_aOneMutantRun_ofAPlansChangedFile_showsTheChangeAsTheSnapshotGivesIt() async throws {
        try selectOneTernary()
        state.apply([
            .testPlanLoaded(LoadedTestPlan(
                path: "/project/muter-mappings.json",
                sha256: "9e1f",
                formatVersion: TestPlanCoding.formatVersion,
                swiftMutatorVersion: muterCore.version,
                scope: nil,
                sources: ProjectTree(
                    listedBy: .git,
                    files: ["Sources/Bar.swift": "0000"],
                    excluded: [],
                    treeSHA256: ProjectTree.treeHash(of: ["Sources/Bar.swift": "0000"])
                ),
                mutatedFiles: nil,
                linkedFiles: nil,
                mutatedPaths: []
            )),
        ])
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(run.change, ["- flag ? 1 : 2", "+ flag ? 2 : 1"])
    }

    // A plan that doesn't record the project's files, as one in format 0 doesn't, isn't checked against them, so its
    // file may have changed too: the change is the one the snapshot gives.
    func test_aOneMutantRun_ofAPlanThatDoesntRecordItsFile_showsTheChangeAsTheSnapshotGivesIt() async throws {
        try selectOneTernary()
        loadPlan(sources: nil)
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(run.change, ["- flag ? 1 : 2", "+ flag ? 2 : 1"])
    }

    // A plan's file as the plan recorded it, here through a symbolic link, by what its link's file held, shows the
    // change from the original file.
    func test_aOneMutantRun_ofAPlansUnchangedFile_showsTheChangeFromTheOriginalFile() async throws {
        let digest = FileDigest.sha256(of: Data(Self.ternarySource.utf8))
        for (sources, linkedFiles) in [
            (["Sources/Bar.swift": digest], nil),
            (["Sources/Bar.swift": ProjectTree.linkPrefix + "0000"], ["Sources/Bar.swift": digest]),
        ] {
            try selectOneTernary()
            loadPlan(sources: sources, linkedFiles: linkedFiles)
            fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
            ioDelegate.testSuiteOutcomes = [.passed, .passed]
            let sent = recordEvents(named: [.oneMutantTested])

            _ = try await sut.run(with: state)

            let run = try XCTUnwrap(sent().last?.object as? OneMutantRun)
            XCTAssertEqual(run.change, ["-2:     return flag ? 1 : 2", "+2:     return flag ? 2 : 1"])
        }
    }

    /// Loads a test plan that records the project's `sources`, each file's SHA-256 by its path, or doesn't, as a plan
    /// in format 0 doesn't, and the SHA-256 of each of `linkedFiles`.
    private func loadPlan(sources: [String: String]?, linkedFiles: [String: String]? = nil) {
        state.apply([
            .testPlanLoaded(LoadedTestPlan(
                path: "/project/muter-mappings.json",
                sha256: "9e1f",
                formatVersion: sources == nil ? 0 : TestPlanCoding.formatVersion,
                swiftMutatorVersion: sources == nil ? nil : muterCore.version,
                scope: nil,
                sources: sources.map {
                    ProjectTree(listedBy: .git, files: $0, excluded: [], treeSHA256: ProjectTree.treeHash(of: $0))
                },
                mutatedFiles: nil,
                linkedFiles: linkedFiles,
                mutatedPaths: []
            )),
        ])
    }

    // Only a run of one mutant prints it on its own.
    func test_aWholeRun_sendsNoOneMutantRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(fileManager.contentsAtPath, ["/project/muter.triage.yml"], "its labels alone: no source file")
    }

    func test_aRun_reportsWithTheProjectsLabels() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        fileManager.fileContentsToReturn = Data(
            "mutants:\n- mutant: Sources/A.swift:3:9 RelationalOperatorReplacement\n  label: equivalent\n".utf8
        )
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        let outcome = try XCTUnwrap(finished().first?.object as? MutationTestOutcome)
        XCTAssertEqual(outcome.triage?.path, "/project/muter.triage.yml")
        XCTAssertEqual(outcome.triage?.entries.map(\.label), [.equivalent])
    }

    // The run checked it as it started: one that broke since mustn't cost a long run its report.
    func test_aTriageFileThatBrokeDuringTheRun_costsOnlyItsLabels() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        fileManager.fileContentsToReturn = Data("mutants: [".utf8)
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        let outcome = try XCTUnwrap(finished().first?.object as? MutationTestOutcome)
        XCTAssertNil(outcome.triage)
        let warned = standardError.linesPassed.contains { $0.contains("no triage labels") }
        XCTAssertTrue(warned, "\(standardError.linesPassed)")
    }

    private static let ternarySource = "func pick(_ flag: Bool) -> Int {\n    return flag ? 1 : 2\n}\n"

    /// Makes the state's one mutant a swapped ternary in `Sources/Bar.swift` of the copy, at the end of
    /// `ternarySource`'s line 2, and selects it, as `--mutant` does, under a 60 s limit.
    @discardableResult
    private func selectOneTernary() throws -> MutantKey {
        let path = "/project_mutated/Sources/Bar.swift"
        let schema = try MutationSchema.make(
            filePath: path,
            mutationOperatorId: .swapTernary,
            position: MutationPosition(utf8Offset: 56, line: 2, column: 24),
            snapshot: .make(before: "flag ? 1 : 2", after: "flag ? 2 : 1", description: "swapped ternary operator")
        )
        state.mutationMapping = try [
            SchemataMutationMapping.make((source: "func bar() { }", schemata: [schema]), filePath: path),
        ]
        let key = MutantKey(
            path: "Sources/Bar.swift", mutationOperatorId: .swapTernary, line: 2, column: 24, occurrence: 0
        )
        state.apply([.mutantSelected(key)])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60
        )
        state.loggingDirectory = "/logs"
        return key
    }
}
