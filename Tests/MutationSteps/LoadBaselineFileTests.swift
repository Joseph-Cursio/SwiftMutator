import ArgumentParser
@testable import muterCore
import XCTest

/// What a run command prints for an error, as `RunCommand.message(showing:)` gives it.
private enum RunCommandTestsMessage {
    static func message(_ error: Error) -> String {
        Run.message(showing: error)
    }
}

/// `--baseline`'s file, loaded as the run starts: refused at once when it can't be read or records another scope.
final class LoadBaselineFileTests: MuterTestCase {
    private var directory = ""
    private var path: String { "\(directory)/\(BaselineFile.fileName)" }
    private let state = MutationTestState()
    private let sut = LoadBaselineFile()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    override func setUp() {
        super.setUp()
        current.fileManager = FileManager.default
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationOperatorList = [.ror, .swapTernary]
    }

    /// Saves a baseline file at `path` of a run with `operators`, and otherwise the state's scope.
    private func writeBaseline(operators: [MutationOperator.Id] = [.swapTernary, .ror]) {
        let file = BaselineFile(
            path: path,
            swiftMutator: "0.1.0",
            score: .init(killed: 0, scored: 0),
            scope: BaselineScope(configuration: state.muterConfiguration, operators: operators, skipCoverage: false),
            survivors: []
        )
        XCTAssertTrue(file.save(using: FileManager.default))
    }

    func test_withoutBaseline_loadsNothing() throws {
        state.runOptions = .make()

        let changes = try sut.run(with: state)

        XCTAssertEqual(changes, [])
    }

    func test_aFileOfTheRunsScope_isLoaded() throws {
        writeBaseline()
        state.runOptions = .make(baseline: path)

        let changes = try sut.run(with: state)

        XCTAssertEqual(changes, [.baselineFileLoaded(try BaselineFile.load(at: path, using: FileManager.default))])
    }

    func test_aFileOfAnotherScope_isRefused_beforeAnyMutantIsTested() throws {
        writeBaseline(operators: [.ror])
        state.runOptions = .make(baseline: path)

        do {
            _ = try sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch let refused as BaselineRefused {
            XCTAssertEqual(refused.reasons, [
                #"operators is ["RelationalOperatorReplacement"] in the baseline file, and "#
                    + #"["RelationalOperatorReplacement","SwapTernary"] in this run."#,
            ])
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: refused), .baselineRefused)
            XCTAssertEqual(RunCommandTestsMessage.message(refused), "\(refused)")
        }
    }

    // An `--exclude` adds to `exclude`, so a run with one is another scope.
    func test_anExtraExclude_isRefused() throws {
        writeBaseline()
        state.runOptions = .make(baseline: path)
        state.muterConfiguration = state.muterConfiguration.overriding(workers: nil, timeout: nil, exclude: ["/Gen/"])

        do {
            _ = try sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch let refused as BaselineRefused {
            XCTAssertEqual(refused.reasons, [#"exclude is [] in the baseline file, and ["/Gen/"] in this run."#])
        }
    }

    // `--mutant` discovers with every operator, and compares nothing, so only its file is checked.
    func test_aOneMutantRun_onlyChecksTheFile() throws {
        writeBaseline(operators: [.ror])
        state.runOptions = .make(baseline: path, mutant: MutantReference(path: "A.swift", line: 3, column: 9))

        let changes = try sut.run(with: state)
        XCTAssertEqual(changes.count, 1)

        try FileManager.default.removeItem(atPath: path)
        do {
            _ = try sut.run(with: state)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue(error is BaselineRefused, "\(error)")
        }
    }

    // Only when asked for: after the configuration, and for a test plan after the plan, which gives the operators.
    func test_theStep_comesOnceTheOperatorsAreChosen() {
        let run = MutationTestHandler(options: .make(baseline: path))
        let names = run.steps.map { "\(type(of: $0))" }
        XCTAssertEqual(names.firstIndex(of: "LoadBaselineFile"), (names.firstIndex(of: "LoadConfiguration") ?? -1) + 1)

        let plan = MutationTestHandler(options: .make(testPlanURL: URL(fileURLWithPath: "/p.json"), baseline: path))
        let planNames = plan.steps.map { "\(type(of: $0))" }
        XCTAssertEqual(
            planNames.firstIndex(of: "LoadBaselineFile"),
            (planNames.firstIndex(of: "LoadMuterTestPlan") ?? -1) + 1
        )

        XCTAssertFalse(MutationTestHandler(options: .make()).steps.contains { $0 is LoadBaselineFile })
    }
}
