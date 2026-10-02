import Foundation

final class FunctionsCoverage {
    private var coverage: [String: [Region]] = [:]

    private init() {}

    init(from coverageData: LLVMCoverage) {
        guard let data = coverageData.data.first else {
            return
        }

        for function in data.functions {
            let functionsWithoutExecutaion = function.regions.include(containsNonExecutionRegion)
            guard let filename = function.filenames.first,
                  !functionsWithoutExecutaion.isEmpty
            else {
                continue
            }

            coverage[filename, default: []].append(contentsOf: functionsWithoutExecutaion)
        }
    }

    /// Code that never ran, or that an inactive `#if` kept out of the build. Gap and expansion
    /// regions also report a zero count, but they describe whitespace and macro expansions rather
    /// than source a mutant could sit in.
    private func containsNonExecutionRegion(_ region: Region) -> Bool {
        region.executionCount == 0
            && (region.kind == .code || region.kind == .skipped)
    }

    func regionsForFile(_ filePath: FilePath) -> [Region] {
        coverage[filePath] ?? []
    }
}
extension FunctionsCoverage: Equatable {
    static func == (lhs: FunctionsCoverage, rhs: FunctionsCoverage) -> Bool {
        lhs.coverage == rhs.coverage
    }
}

extension FunctionsCoverage: Nullable {
    static var null: FunctionsCoverage = .init()
}
