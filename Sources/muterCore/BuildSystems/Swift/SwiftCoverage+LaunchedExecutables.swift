import Foundation

extension SwiftCoverage {
    /// The executables of `package`, the tested package, in `binPath`, whose code its tests ran, as a test runs a
    /// package's command-line tool with `Process`. Exported with the test bundles, their code and that of the
    /// libraries only they link count as the tests' too, so their files are mutated, and a test that runs one can kill
    /// their mutants. A process the tests start inherits their `LLVM_PROFILE_FILE`, and writes its own profile into the
    /// `codecov` folder that is merged into `profile`, when it exits rather than being killed. One the test gives an
    /// `environment` of its own writes it elsewhere, and reads as not run.
    ///
    /// An executable ran when a file of its own executable target has a covered line in an export of `bundles` and
    /// every executable: the libraries it shares with the bundles have the bundles' counts in it too, so they say
    /// nothing. One that didn't run, as an example nothing starts, is left out rather than counting its files as never
    /// run. A testable executable, one a test target depends on, is linked into its bundle, so tests that call it
    /// count it as run without starting it, which changes nothing: the bundle maps its code and libraries already.
    /// None when that export fails: the bundles' coverage stands then. `llvmCov` is how to run llvm-cov.
    func executablesTheTestsRan(
        of package: SwiftPackageSources.Package,
        in binPath: String,
        besides bundles: [String],
        profile: String,
        llvmCov: (executable: String, arguments: [String])
    ) async -> [String] {
        let candidates = executables(of: package, in: binPath)
        guard !candidates.isEmpty,
              case let .success(export) = await llvmCovExport(
                  of: bundles + candidates.map(\.binary),
                  profile: profile,
                  llvmCov: llvmCov,
                  summaryOnly: true
              ),
              let summary = try? JSONDecoder().decode(ExportSummary.self, from: export)
        else {
            return []
        }

        // Compared with every link resolved: a target's files are listed with their folders' links resolved, and
        // llvm-cov names a file by the folder SwiftPM was given, link or not. Nor does a file in a `Tests` folder, as
        // a test fixture's tool is, count as a test file here.
        let root = fileManager.currentDirectoryPath
        let ran = Set(
            summary.data.flatMap(\.files).filter { $0.summary.lines.covered > 0 }.map(\.filename.canonicalPath)
        )
        return candidates
            .filter { candidate in candidate.ownFiles.contains { ran.contains((root + "/" + $0).canonicalPath) } }
            .map(\.binary)
    }

    /// Each executable product of `package` that the coverage run built in `binPath`, by its binary there, which is
    /// named after the product, with the files of its executable target, relative to the project, in name order.
    private func executables(
        of package: SwiftPackageSources.Package,
        in binPath: String
    ) -> [(binary: String, ownFiles: [FilePath])] {
        let executableTargets = Dictionary(
            package.targets.filter { $0.type == "executable" }.compactMap { target in
                target.name.map { ($0, target.files) }
            }
        ) { first, _ in first }
        return package.products.sorted { $0.key < $1.key }.compactMap { name, targets in
            let ownFiles = targets.flatMap { executableTargets[$0] ?? [] }
            let binary = binPath + "/" + name
            guard !ownFiles.isEmpty, fileManager.fileExists(atPath: binary) else { return nil }
            return (binary, ownFiles)
        }
    }

    /// The files of an `llvm-cov export -summary-only`, each with its summary alone.
    private struct ExportSummary: Decodable {
        let data: [ExportSummaryData]
    }

    /// One export of an `ExportSummary`.
    private struct ExportSummaryData: Decodable {
        let files: [LLVMCoverage.File]
    }
}
