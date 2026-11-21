@testable import muterCore
import XCTest

/// The gate keys, `baseline`, `maxNewSurvivors`, `maxScoreDrop` and `maxDoubtfulKills`, with the run's flags in, each
/// in place of its own key (`RunGates.overridden(by:in:)`).
extension LoadConfigurationTests {
    private func gates(
        of yaml: String,
        options: Run.Options = .make(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RunGates? {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("executable: /usr/bin/swift\narguments: [test]\n\(yaml)".utf8)
        state.runOptions = options

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)", file: file, line: line)
            return nil
        }
        return configuration.gates
    }

    // Each key alone takes effect, as its flag would: a key's baseline file is the project's, and allows no new
    // survivor unless `maxNewSurvivors` says otherwise.
    func test_theGateKeys_takeEffect_withTheBaselineFile_inTheProjectsFolder() async throws {
        let all = try await gates(
            of: "baseline: ci/muter.baseline.yml\nmaxNewSurvivors: 2\nmaxScoreDrop: 1.5\nmaxDoubtfulKills: 0\n"
        )
        XCTAssertEqual(
            all,
            RunGates(
                baseline: "\(fixturesDirectory)/ci/muter.baseline.yml",
                maxNewSurvivors: 2,
                maxScoreDrop: 1.5,
                maxDoubtfulKills: 0
            )
        )

        let baselineAlone = try await gates(of: "baseline: muter.baseline.yml\n")
        XCTAssertEqual(baselineAlone, RunGates(baseline: "\(fixturesDirectory)/muter.baseline.yml", maxNewSurvivors: 0))
        let absolute = try await gates(of: "baseline: /ci/muter.baseline.yml\n")
        XCTAssertEqual(absolute?.baseline, "/ci/muter.baseline.yml")
        let home = try await gates(of: "baseline: \"~/muter.baseline.yml\"\n")
        XCTAssertEqual(home?.baseline, URL.expandingTilde("~/muter.baseline.yml"))
        let doubtfulKillsAlone = try await gates(of: "maxDoubtfulKills: 4\n")
        XCTAssertEqual(doubtfulKillsAlone, RunGates(maxDoubtfulKills: 4))
        let none = try await gates(of: "")
        XCTAssertEqual(none, RunGates())
    }

    // With `--project-folder` the run has moved into that folder before it reads the file, and resolves the key
    // against it, not against the folder the command was given in, nor the one `-c`'s file is in.
    func test_theBaselineKey_isResolvedAgainstTheProjectFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/projects/App"
        let moved = try await gates(
            of: "baseline: muter.baseline.yml\n",
            options: .make(projectFolder: URL(fileURLWithPath: "/projects/App"))
        )
        XCTAssertEqual(moved?.baseline, "/projects/App/muter.baseline.yml")
        let elsewhere = try await gates(
            of: "baseline: muter.baseline.yml\n",
            options: .make(configurationURL: URL(fileURLWithPath: "/shared/ci/muter.conf.yml"))
        )
        XCTAssertEqual(elsewhere?.baseline, "/projects/App/muter.baseline.yml")
    }

    // Each flag takes the place of its own key alone, and a key's count applies to the flag's file, and the other way
    // round.
    func test_eachGateFlag_replacesItsKey() async throws {
        let keys = "baseline: muter.baseline.yml\nmaxNewSurvivors: 2\nmaxScoreDrop: 1.5\nmaxDoubtfulKills: 0\n"
        let flags = Run.Options.make(baseline: "/ci/b.yml", maxNewSurvivors: 5, maxScoreDrop: 3, maxDoubtfulKills: 7)
        let replaced = try await gates(of: keys, options: flags)
        XCTAssertEqual(
            replaced,
            RunGates(baseline: "/ci/b.yml", maxNewSurvivors: 5, maxScoreDrop: 3, maxDoubtfulKills: 7)
        )

        let baselineFlag = try await gates(of: keys, options: .make(baseline: "/ci/b.yml"))
        XCTAssertEqual(
            baselineFlag,
            RunGates(baseline: "/ci/b.yml", maxNewSurvivors: 2, maxScoreDrop: 1.5, maxDoubtfulKills: 0)
        )
        let countFlag = try await gates(of: "baseline: muter.baseline.yml\n", options: .make(maxNewSurvivors: 3))
        XCTAssertEqual(countFlag, RunGates(baseline: "\(fixturesDirectory)/muter.baseline.yml", maxNewSurvivors: 3))
        let dropFlag = try await gates(of: "baseline: muter.baseline.yml\n", options: .make(maxScoreDrop: 0.5))
        XCTAssertEqual(dropFlag?.maxScoreDrop, 0.5)
        let keysCount = try await gates(of: "maxNewSurvivors: 4\nmaxScoreDrop: 2\n", options: .make(baseline: "/b.yml"))
        XCTAssertEqual(keysCount, RunGates(baseline: "/b.yml", maxNewSurvivors: 4, maxScoreDrop: 2))
        let flagAlone = try await gates(of: "", options: .make(baseline: "/b.yml"))
        XCTAssertEqual(flagAlone, RunGates(baseline: "/b.yml", maxNewSurvivors: 0))
    }

    // The run that writes the key's file, with no `--baseline`, sets the key and its counts aside, as that file may be
    // missing or of another scope until the run writes it. `--baseline` compares as before, with the key's counts, and
    // a `--write-baseline` of another file leaves the key in place.
    func test_aRunThatWritesTheKeysFile_setsTheKeyAside() async throws {
        let keys = "baseline: muter.baseline.yml\nmaxNewSurvivors: 2\nmaxScoreDrop: 1.5\nmaxDoubtfulKills: 0\n"
        let keyFile = "\(fixturesDirectory)/muter.baseline.yml"

        let writing = try await gates(of: keys, options: .make(writeBaseline: keyFile))
        XCTAssertEqual(writing, RunGates(maxDoubtfulKills: 0))
        let dotted = "\(fixturesDirectory)/./muter.baseline.yml"
        let spelledOtherwise = try await gates(of: keys, options: .make(writeBaseline: dotted))
        XCTAssertEqual(spelledOtherwise, RunGates(maxDoubtfulKills: 0))

        let comparing = try await gates(of: keys, options: .make(baseline: keyFile, writeBaseline: keyFile))
        XCTAssertEqual(
            comparing,
            RunGates(baseline: keyFile, maxNewSurvivors: 2, maxScoreDrop: 1.5, maxDoubtfulKills: 0)
        )
        let another = try await gates(of: keys, options: .make(writeBaseline: "/ci/other.baseline.yml"))
        XCTAssertEqual(
            another,
            RunGates(baseline: keyFile, maxNewSurvivors: 2, maxScoreDrop: 1.5, maxDoubtfulKills: 0)
        )
    }

    // A count only says what a baseline file allows: with neither `--baseline` nor `baseline:` it is a configuration
    // error, the flag's as the key's. `maxDoubtfulKills` needs no file.
    func test_aCountWithoutABaselineFile_isRefused() async throws {
        struct Refusal {
            let yaml: String
            let options: Run.Options
            let given: String
        }
        let refusals = [
            Refusal(yaml: "maxNewSurvivors: 0\n", options: .make(), given: "`maxNewSurvivors:`"),
            Refusal(yaml: "maxScoreDrop: 2\n", options: .make(), given: "`maxScoreDrop:`"),
            Refusal(yaml: "", options: .make(maxNewSurvivors: 1), given: "--max-new-survivors"),
            Refusal(yaml: "", options: .make(maxScoreDrop: 1), given: "--max-score-drop"),
            Refusal(yaml: "maxScoreDrop: 2\n", options: .make(maxNewSurvivors: 1), given: "--max-new-survivors"),
        ]
        for refusal in refusals {
            fileManager.fileExistsToReturn = [false, true]
            let text = "executable: /usr/bin/swift\narguments: [test]\n\(refusal.yaml)"
            fileManager.fileContentsToReturn = Data(text.utf8)
            state.runOptions = refusal.options

            await assertThrowsMuterError(
                try await sut.run(with: state),
                .configurationParsingError(reason: "\(refusal.given) only applies with `baseline:` or --baseline."),
                refusal.given
            )
        }
    }

    // `mutate-without-running` tests nothing: it ignores the keys, refuses none of them, and its plan records none.
    func test_aRunThatMakesATestPlan_ignoresTheGateKeys() async throws {
        let plan = try await gates(
            of: "baseline: muter.baseline.yml\nmaxNewSurvivors: 1\n",
            options: .make(createTestPlan: true)
        )
        XCTAssertEqual(plan, RunGates())
        let refusedElsewhere = try await gates(of: "maxScoreDrop: 2\n", options: .make(createTestPlan: true))
        XCTAssertEqual(refusedElsewhere, RunGates())
    }
}
