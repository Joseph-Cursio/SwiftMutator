import ArgumentParser
@testable import muterCore
import XCTest

/// What a run command prints for an error, as `RunCommand.message(showing:)` gives it.
private enum RunCommandTestsMessage {
    static func message(_ error: Error) -> String {
        Run.message(showing: error)
    }
}

/// The run's baseline file, `--baseline`'s or `baseline:`'s, as `LoadConfiguration` puts them in the configuration's
/// gates, loaded as the run starts: refused at once when it can't be read or records another scope.
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

    /// The run's gates name `path` as its baseline file, as `LoadConfiguration` leaves them for `--baseline` or
    /// `baseline:`.
    private func comparing(with path: String) {
        state.muterConfiguration.gates = RunGates(baseline: path, maxNewSurvivors: 0)
    }

    // The flags as given aren't read: `LoadConfiguration` puts them in the configuration's gates, with the keys.
    func test_withoutBaseline_loadsNothing() throws {
        writeBaseline()
        state.runOptions = .make(baseline: path)

        let changes = try sut.run(with: state)

        XCTAssertEqual(changes, [])
    }

    // `--baseline`'s missing file: `--write-baseline` makes one.
    func test_aBaselineFlag_whoseFileIsMissing_isRefused_withStatus8() throws {
        state.runOptions = .make(baseline: path)
        comparing(with: path)

        XCTAssertThrowsError(try sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? BaselineRefused,
                BaselineRefused(
                    path: path,
                    reasons: ["There is no baseline file there. Write one with --write-baseline."]
                )
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .baselineRefused)
        }
    }

    // A `baseline:` key whose file isn't there yet refuses a run that tests, as `--baseline` does, so the message says
    // the key named the file, and that a run writing it sets the key aside.
    func test_aBaselineKey_whoseFileIsMissing_isRefused_withStatus8_sayingTheKeyNamedIt() throws {
        comparing(with: path)

        XCTAssertThrowsError(try sut.run(with: state)) { error in
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .baselineRefused)
            XCTAssertEqual(
                "\(error)",
                "SwiftMutator won't compare the survivors with the baseline file \(Logger.shellQuoted(path)), which "
                    + "the configuration's baseline: names:\n"
                    + "  - There is no baseline file there.\n"
                    + "A run whose --write-baseline names this file sets baseline: aside, and writes it."
            )
        }
    }

    func test_aFileOfTheRunsScope_isLoaded() throws {
        writeBaseline()
        comparing(with: path)

        let changes = try sut.run(with: state)

        XCTAssertEqual(changes, [.baselineFileLoaded(try BaselineFile.load(at: path, using: FileManager.default))])
    }

    func test_aFileOfAnotherScope_isRefused_beforeAnyMutantIsTested() throws {
        writeBaseline(operators: [.ror])
        comparing(with: path)

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
            XCTAssertTrue(refused.namedByKey)
            XCTAssertEqual(
                refused.advice,
                "Its survivors are another scope's mutants, so none can be compared. Run as the baseline file's "
                    + "run did, or write a new baseline file with --write-baseline from a run of this scope. "
                    + "A run whose --write-baseline names this file sets baseline: aside, and writes it."
            )
        }
    }

    // `--baseline`'s file of another scope: the refusal names the flag's file, with no word of the key.
    func test_aFlagsFileOfAnotherScope_isRefused_withoutTheKeysAdvice() throws {
        writeBaseline(operators: [.ror])
        state.runOptions = .make(baseline: path)
        comparing(with: path)

        XCTAssertThrowsError(try sut.run(with: state)) { error in
            let refused = error as? BaselineRefused
            XCTAssertEqual(refused?.namedByKey, false)
            XCTAssertFalse("\(error)".contains("baseline:"), "\(error)")
        }
    }

    // An `--exclude` adds to `exclude`, so a run with one is another scope.
    func test_anExtraExclude_isRefused() throws {
        writeBaseline()
        state.muterConfiguration = state.muterConfiguration.overriding(workers: nil, timeout: nil, exclude: ["/Gen/"])
        comparing(with: path)

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
        comparing(with: path)
        state.runOptions = .make(mutant: MutantReference(path: "A.swift", line: 3, column: 9))

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

    // After the configuration, and for a test plan after the plan, which gives the operators. In every run that tests,
    // without `--baseline` too, as the configuration may give the file; never in one that makes a plan.
    func test_theStep_comesOnceTheOperatorsAreChosen() {
        let run = MutationTestHandler(options: .make())
        let names = run.steps.map { "\(type(of: $0))" }
        XCTAssertEqual(names.firstIndex(of: "LoadBaselineFile"), (names.firstIndex(of: "LoadConfiguration") ?? -1) + 1)

        let plan = MutationTestHandler(options: .make(testPlanURL: URL(fileURLWithPath: "/p.json")))
        let planNames = plan.steps.map { "\(type(of: $0))" }
        XCTAssertEqual(
            planNames.firstIndex(of: "LoadBaselineFile"),
            (planNames.firstIndex(of: "LoadMuterTestPlan") ?? -1) + 1
        )

        let makingAPlan = MutationTestHandler(options: .make(createTestPlan: true))
        XCTAssertFalse(makingAPlan.steps.contains { $0 is LoadBaselineFile })
    }
}
