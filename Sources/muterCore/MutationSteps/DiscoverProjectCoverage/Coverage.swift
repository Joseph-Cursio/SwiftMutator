import Foundation

final class Coverage {
    let percent: Int
    let filesWithoutCoverage: [FilePath]
    let functionsCoverage: FunctionsCoverage
    /// The tests that failed in the coverage run, whose test processes' profiles were merged regardless; nil when every
    /// test passed.
    let testsFailedWithCoverageOn: FailedTestLine.FailedTests?

    init(
        percent: Int = 0,
        filesWithoutCoverage: [FilePath] = [],
        functionsCoverage: FunctionsCoverage = .null,
        testsFailedWithCoverageOn: FailedTestLine.FailedTests? = nil
    ) {
        self.percent = percent
        self.filesWithoutCoverage = filesWithoutCoverage
        self.functionsCoverage = functionsCoverage
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
