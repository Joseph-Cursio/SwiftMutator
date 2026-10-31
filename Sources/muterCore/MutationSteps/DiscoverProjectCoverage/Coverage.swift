import Foundation

final class Coverage: Sendable {
    let percent: Int
    let filesWithoutCoverage: [FilePath]
    let functionsCoverage: FunctionsCoverage
    /// The project's own source files that llvm-cov's export of the tests' binaries names, by their path in the
    /// project, whether the tests ran them or not; nil when that isn't known. A file it doesn't name has no code in any
    /// binary the coverage run built and read, so no test can kill a mutant in it, and none of its lines are counted.
    let filesInCoverage: [FilePath]?
    /// The tests that failed in the coverage run, whose test processes' coverage was gathered regardless; nil when
    /// every test passed.
    let testsFailedWithCoverageOn: FailedTestLine.FailedTests?

    init(
        percent: Int = 0,
        filesWithoutCoverage: [FilePath] = [],
        functionsCoverage: FunctionsCoverage = .null,
        filesInCoverage: [FilePath]? = nil,
        testsFailedWithCoverageOn: FailedTestLine.FailedTests? = nil
    ) {
        self.percent = percent
        self.filesWithoutCoverage = filesWithoutCoverage
        self.functionsCoverage = functionsCoverage
        self.filesInCoverage = filesInCoverage
        self.testsFailedWithCoverageOn = testsFailedWithCoverageOn
    }

    func coverage(ofFile filePath: FilePath) -> FileCoverage {
        functionsCoverage.coverage(ofFile: filePath)
    }
}

extension Coverage: Equatable {
    static func == (lhs: Coverage, rhs: Coverage) -> Bool {
        (
            lhs.percent == rhs.percent
                && lhs.filesWithoutCoverage == rhs.filesWithoutCoverage
                && lhs.functionsCoverage == rhs.functionsCoverage
                && lhs.filesInCoverage == rhs.filesInCoverage
                && lhs.testsFailedWithCoverageOn == rhs.testsFailedWithCoverageOn
        )
            || lhs === rhs
    }
}

extension Coverage: Nullable {
    static var null: Coverage {
        Coverage(
            percent: -1,
            filesWithoutCoverage: [],
            functionsCoverage: .null
        )
    }
}
