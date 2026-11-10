import Foundation
@testable import muterCore
import TestingExtensions

/// The progress's total: the mutants the session tests, which the baseline's log carries, not those discovered.
final class LoggerProgressTotalTests: MuterTestCase {
    private let sut = Logger()

    // run --mutant discovers every mutant and then tests one, so its total is the one the baseline's log carries, not
    // the number discovered: "1 of 3 (33%)" and a time left of two more mutants' runs would be false.
    func test_withoutATerminal_theTotal_isTheMutantsThisSessionTests_notTheMutantsDiscovered() throws {
        current.standardOutIsATerminal = false
        let seconds = Locked<UInt64>(0)
        let start = current.now()
        current.now = { start.addingTimeInterval(TimeInterval(seconds.value)) }
        current.instant = { DispatchTime(uptimeNanoseconds: (1 + seconds.value) * 1_000_000_000) }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try discoveredMapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 1)
        )
        XCTAssertTrue(printer.linesPassed.last?.hasSuffix("0 of 1 (0%) | 1 min left"), "\(printer.linesPassed)")
        sut.mutantRunsStarted()
        seconds.change { $0 += 60 }
        sut.newMutationTestOutcomeAvailable(mutation: .make(testSuiteOutcome: .failed))

        let line = printer.linesPassed.last ?? ""
        XCTAssertTrue(line.contains("] 1 of 1 (100%) | 1 killed | 0 min left"), line)
    }

    func test_theProgressBar_countsTheMutantsThisSessionTests_notTheMutantsDiscovered() throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = {
            nanoseconds.change { time in
                time += 200_000_000
                return DispatchTime(uptimeNanoseconds: time)
            }
        }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try discoveredMapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 1)
        )
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))

        let draws = printer.linesPassed.filter { $0.contains("Percentage complete:") }
        XCTAssertEqual(draws.map(percent), ["0%", "100%"])
    }

    /// A file's mapping with one mutant, as discovery reports it.
    private func discoveredMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [.make(filePath: "/tmp/project/file.swift", position: .firstPosition)]
            )
        )
    }

    private func percent(_ draw: String) -> String {
        guard let sign = draw.range(of: "%") else { return "" }
        return String(draw[..<sign.lowerBound].reversed().prefix(while: \.isNumber).reversed()) + "%"
    }
}
