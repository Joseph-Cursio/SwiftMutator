@testable import muterCore
import XCTest

/// The `oneWorkerSimulator:` key as a configuration gives it: left out, or set to true or false.
private enum OneWorkerSimulatorKey: CustomStringConvertible {
    case unset
    case setToTrue
    case setToFalse

    var description: String {
        switch self {
        case .unset: "nil"
        case .setToTrue: "true"
        case .setToFalse: "false"
        }
    }
}

/// A run's settings for `SimulatorWorkerSetup.oneWorkerPlan(for:state:)`, each at the default that gets a
/// simulator checked against the baseline unless a case says otherwise, and the plan expected for them.
private struct PlanCase: CustomStringConvertible {
    let expected: SimulatorWorkerSetup.OneWorkerPlan
    var key = OneWorkerSimulatorKey.unset
    var executable = "/usr/bin/xcodebuild"
    var workers: Int?
    var destination: String? = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    var arguments: [String] = []
    var selected = false
    var mutants = 6
    var parallelizes = true

    var description: String {
        "key \(key), \(executable), workers \(workers.map(String.init) ?? "nil"), "
            + "destination \(destination ?? "none"), arguments \(arguments), selected \(selected), mutants \(mutants), "
            + "parallelizes \(parallelizes)"
    }
}

/// Whether one xcodebuild worker gets a simulator of its own, before the baseline and after it.
final class SimulatorWorkerSetupTests: XCTestCase {
    func test_oneWorkerPlan_onAuto_isASimulatorOnlyWhenItShouldBeFaster() {
        let cases: [PlanCase] = [
            PlanCase(expected: .simulator(checkedAgainstBaseline: true)),
            PlanCase(expected: .simulator(checkedAgainstBaseline: true), workers: 1),
            PlanCase(expected: .noSimulator, executable: "/usr/bin/swift", destination: nil),
            PlanCase(expected: .noSimulator, executable: "/bin/sh"),
            PlanCase(expected: .noSimulator, workers: 2, mutants: 1),
            PlanCase(expected: .noSimulator, destination: "platform=macOS"),
            PlanCase(expected: .noSimulator, destination: "platform=macOS,variant=Mac Catalyst"),
            PlanCase(expected: .noSimulator, destination: "generic/platform=iOS Simulator"),
            PlanCase(expected: .noSimulator, destination: nil),
            PlanCase(expected: .noSimulator, selected: true),
            PlanCase(expected: .noSimulator, mutants: 1),
            PlanCase(expected: .noSimulator, mutants: 2),
            PlanCase(expected: .noSimulator, mutants: 5),
            PlanCase(expected: .noSimulator, parallelizes: false),
            // The test command's parallel testing arguments reach a mutant's run on the destination as they reach the
            // baseline: off, it clones nothing; on, it clones whatever the scheme says; tuned, the baseline shows how.
            PlanCase(expected: .noSimulator, arguments: ["-parallel-testing-enabled", "NO"]),
            PlanCase(
                expected: .simulator(checkedAgainstBaseline: true),
                arguments: ["-parallel-testing-enabled", "YES"],
                parallelizes: false
            ),
            PlanCase(
                expected: .simulator(checkedAgainstBaseline: true),
                arguments: ["-parallel-testing-worker-count", "3"]
            ),
            PlanCase(expected: .noSimulator, arguments: ["-parallel-testing-worker-count", "3"], parallelizes: false),
            PlanCase(expected: .noSimulator, arguments: ["-parallel-testing-worker-count", "3"], mutants: 5),
        ]

        assertPlans(cases)
    }

    func test_oneWorkerPlan_withTheKey_isASimulatorWheneverItCanBe_orNever() {
        let needsASimulator = "a simulator of its own needs a first `-destination` that is a simulator"
        let cases: [PlanCase] = [
            PlanCase(expected: .simulator(checkedAgainstBaseline: false), key: .setToTrue),
            PlanCase(expected: .simulator(checkedAgainstBaseline: false), key: .setToTrue, mutants: 2),
            PlanCase(expected: .simulator(checkedAgainstBaseline: false), key: .setToTrue, parallelizes: false),
            PlanCase(
                expected: .simulator(checkedAgainstBaseline: false),
                key: .setToTrue,
                arguments: ["-parallel-testing-enabled", "YES"]
            ),
            PlanCase(
                expected: .simulator(checkedAgainstBaseline: false),
                key: .setToTrue,
                arguments: ["-parallel-testing-enabled", "NO"]
            ),
            PlanCase(expected: .declined(needsASimulator), key: .setToTrue, destination: "platform=macOS"),
            PlanCase(
                expected: .declined(needsASimulator),
                key: .setToTrue,
                destination: "generic/platform=iOS Simulator"
            ),
            PlanCase(expected: .declined(needsASimulator), key: .setToTrue, destination: nil),
            PlanCase(expected: .noSimulator, key: .setToTrue, mutants: 1),
            PlanCase(expected: .noSimulator, key: .setToTrue, selected: true),
            PlanCase(expected: .noSimulator, key: .setToTrue, executable: "/usr/bin/swift"),
            PlanCase(expected: .noSimulator, key: .setToTrue, workers: 3),
            PlanCase(expected: .noSimulator, key: .setToFalse),
            PlanCase(expected: .noSimulator, key: .setToFalse, destination: "platform=macOS"),
        ]

        assertPlans(cases)
    }

    func test_theOneWorkerSimulator_isDropped_unlessTheBaselineShowsItShouldBeFaster() {
        XCTAssertEqual(
            SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(nil),
            "the baseline printed no parallel testing line to tell how many clones its tests ran on; "
                + "`oneWorkerSimulator: true` tests on a simulator of its own anyway"
        )
        XCTAssertNil(SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(.init(clones: 1, testSeconds: 60)))
        XCTAssertNil(SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(.init(clones: 3, testSeconds: 9)))
        XCTAssertNil(SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(.init(clones: 3, testSeconds: 10)))
        XCTAssertEqual(
            SimulatorWorkerSetup.reasonToDropTheOneWorkerSimulator(.init(clones: 2, testSeconds: 11)),
            "the baseline's parallel testing spread 11.0 s of tests over 2 clones, which one at a time on one "
                + "simulator could make slower; `oneWorkerSimulator: true` tests on one anyway"
        )
    }

    private func assertPlans(_ cases: [PlanCase], file: StaticString = #filePath, line: UInt = #line) {
        for testCase in cases {
            let state = MutationTestState()
            state.muterConfiguration = MuterConfiguration(
                executable: testCase.executable,
                arguments: (testCase.destination.map { ["-destination", $0] } ?? []) + testCase.arguments + ["test"],
                mutationTestWorkers: testCase.workers,
                oneWorkerSimulator: testCase.key == .unset ? nil : testCase.key == .setToTrue
            )
            state.apply([.projectXCTestRun(testCase.parallelizes ? .parallelizing : muterCore.XCTestRun())])
            if testCase.selected {
                let key = MutantKey(path: "file.swift", mutationOperatorId: .ror, line: 1, column: 0, occurrence: 0)
                state.apply([.mutantSelected(key)])
            }
            XCTAssertEqual(
                SimulatorWorkerSetup.oneWorkerPlan(for: testCase.mutants, state: state),
                testCase.expected,
                "\(testCase)",
                file: file,
                line: line
            )
        }
    }
}
