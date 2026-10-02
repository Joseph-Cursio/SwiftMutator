import Foundation

final class FunctionsCoverage {
    /// Keyed by canonical path, since llvm-cov may spell a file's path differently from SwiftMutator.
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

            coverage[filename.canonicalPath, default: []].append(contentsOf: functionsWithoutExecutaion)
        }
    }

    private func containsNonExecutionRegion(_ region: Region) -> Bool {
        region.executionCount == 0
    }

    func regionsForFile(_ filePath: FilePath) -> [Region] {
        coverage[filePath.canonicalPath] ?? []
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
