import Foundation

final class FunctionsCoverage {
    /// Keyed by canonical path, since llvm-cov may spell a file's path differently from SwiftMutator.
    private var coverage: [String: FileCoverage] = [:]

    private init() {}

    init(from coverageData: LLVMCoverage) {
        guard let data = coverageData.data.first else {
            return
        }

        var functionsByFile: [String: [[Region]]] = [:]
        for function in data.functions {
            let regions = function.regions.include(isSource)
            guard let filename = function.filenames.first,
                  !regions.isEmpty
            else {
                continue
            }

            functionsByFile[filename.canonicalPath, default: []].append(regions)
        }
        coverage = functionsByFile.mapValues(FileCoverage.init(functions:))
    }

    /// Code, or code an inactive `#if` kept out of the build. Gap and expansion regions describe whitespace and macro
    /// expansions rather than source a mutant could sit in.
    private func isSource(_ region: Region) -> Bool {
        region.kind == .code || region.kind == .skipped
    }

    func coverage(ofFile filePath: FilePath) -> FileCoverage {
        coverage[filePath.canonicalPath] ?? .none
    }

    /// Code that never ran, or that an inactive `#if` kept out of the build.
    func regionsForFile(_ filePath: FilePath) -> [Region] {
        coverage(ofFile: filePath).functions.joined().include { $0.executionCount == 0 }
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

/// The regions llvm-cov reports in a file, by function, in its order: a function's first region is its whole body.
struct FileCoverage: Equatable {
    let functions: [[Region]]

    static let none = FileCoverage(functions: [])
}
