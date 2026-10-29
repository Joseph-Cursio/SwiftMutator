import Foundation

final class FunctionsCoverage: Sendable {
    /// Keyed by canonical path, since llvm-cov may spell a file's path differently from SwiftMutator.
    private let coverage: [String: FileCoverage]

    private init() {
        coverage = [:]
    }

    init(from coverageData: LLVMCoverage) {
        guard let data = coverageData.data.first else {
            coverage = [:]
            return
        }

        var functionsByFile: [String: [Function]] = [:]
        for function in data.functions {
            let regions = function.regions.include(Self.isSource)
            guard let filename = function.filenames.first,
                  !regions.isEmpty
            else {
                continue
            }

            functionsByFile[filename.canonicalPath, default: []].append(
                Function(name: function.name, filenames: function.filenames, regions: regions)
            )
        }
        coverage = functionsByFile.mapValues { FileCoverage(functions: Self.mergingCopies(of: $0)) }
    }

    /// The regions of a file's `functions`, with the copies of each merged. A file built into several binaries, as one
    /// an app shares with its extension is, has a copy of each function in each, under that module's name, with the
    /// same body, and the extension's never ran if the tests ran only the app. That copy would hide what the app's ran:
    /// the code its build left out of an `#if`, and for a closure, its count of 0, read as the closure's. So a skipped
    /// region counts only if each copy that ran skips that code too, and of a closure's copies only the one called most
    /// is kept, with the functions that make it. Those can share its body, as a property's initializer does, but
    /// aren't copies: the closure's name starts with theirs.
    private static func mergingCopies(of functions: [Function]) -> [[Region]] {
        let body = { (index: Int) in functions[index].regions.first { $0.kind == .code } }
        let name = { (index: Int) in functions[index].name ?? "" }
        let count = { (index: Int) in body(index)?.executionCount ?? 0 }
        // llvm-cov names every function, but a test's record may have no name.
        let sharingABody = Dictionary(
            grouping: functions.indices.filter { functions[$0].name != nil && body($0) != nil },
            by: { body($0).map { [$0.lineStart, $0.columnStart, $0.lineEnd, $0.columnEnd] } }
        )
        var regions = functions.map(\.regions)
        var dropped = Set<Int>()
        for records in sharingABody.values {
            let copies = records.filter { record in
                !records.contains { $0 != record && name($0).hasPrefix(name(record)) }
            }
            guard copies.count > 1 else {
                continue
            }
            if copies.allSatisfy({ name($0).firstMatchOf(#"f[Uu][0-9]*_$"#) != nil }),
               let calledMost = copies.max(by: { count($0) < count($1) }) {
                dropped.formUnion(records.filter { $0 != calledMost && !name(calledMost).hasPrefix(name($0)) })
            }
            let ran = copies.filter { count($0) > 0 }
            let skips = { (index: Int, code: Region) in
                functions[index].regions.contains { $0.kind == .skipped && $0.contains(code) }
            }
            for copy in copies where !dropped.contains(copy) {
                regions[copy] = regions[copy].exclude { region in
                    region.kind == .skipped && ran.contains { $0 != copy && !skips($0, region) }
                }
            }
        }

        return regions.indices.exclude(dropped.contains).map { regions[$0] }
    }

    /// Code, or code an inactive `#if` kept out of the build. Gap and expansion regions describe whitespace and macro
    /// expansions rather than source a mutant could sit in.
    private static func isSource(_ region: Region) -> Bool {
        region.kind == .code || region.kind == .skipped
    }

    func coverage(ofFile filePath: FilePath) -> FileCoverage {
        coverage[filePath.canonicalPath] ?? .empty
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
    static let null: FunctionsCoverage = .init()
}

/// The regions llvm-cov reports in a file, by function, in its order: a function's first region is its whole body.
struct FileCoverage: Equatable {
    let functions: [[Region]]

    static let empty = FileCoverage(functions: [])
}
