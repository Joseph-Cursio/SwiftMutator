@testable import muterCore

extension Coverage {
    static func make(
        percent: Int = 0,
        filesWithoutCoverage: [FilePath] = [],
        functionsCoverage: FunctionsCoverage = .null,
        filesInCoverage: [FilePath]? = nil,
        testsFailedWithCoverageOn: FailedTestLine.FailedTests? = nil
    ) -> Coverage {
        Coverage(
            percent: percent,
            filesWithoutCoverage: filesWithoutCoverage,
            functionsCoverage: functionsCoverage,
            filesInCoverage: filesInCoverage,
            testsFailedWithCoverageOn: testsFailedWithCoverageOn
        )
    }
}

extension Region {
    static func make(
        lineStart: Int = 0,
        columnStart: Int = 0,
        lineEnd: Int = 0,
        columnEnd: Int = 0,
        executionCount: Int = 0,
        kind: Region.Kind = .code
    ) -> Region {
        Region(
            lineStart: lineStart,
            columnStart: columnStart,
            lineEnd: lineEnd,
            columnEnd: columnEnd,
            executionCount: executionCount,
            kind: kind
        )
    }
}

extension FileCoverage {
    /// Each region a function of its own, as hand-written regions the tests never ran are.
    static func make(regionsWithoutCoverage: [Region]) -> FileCoverage {
        FileCoverage(functions: regionsWithoutCoverage.map { [$0] })
    }

    /// Functions as llvm-cov exports them: each region `[line, column, end line, end column, count]`, with its kind
    /// after that when it isn't code, and each function's first region its body.
    static func llvmCov(_ functions: [[[Int]]]) -> FileCoverage {
        FileCoverage(functions: functions.map { regions in
            regions.map { fields in
                Region(
                    lineStart: fields[0],
                    columnStart: fields[1],
                    lineEnd: fields[2],
                    columnEnd: fields[3],
                    executionCount: fields[4],
                    kind: fields.count > 5 ? Region.Kind(rawValue: fields[5]) ?? .other : .code
                )
            }
        })
    }
}
