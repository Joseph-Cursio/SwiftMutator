import Foundation

/// A file of a target in xccov's JSON report: how many of its lines the tests could run and ran.
struct CoverageReportFile: Decodable {
    let path: String
    let coveredLines: Int
    let executableLines: Int
}

/// What SwiftMutator reads of xccov's JSON report: each target, and how many of each of its files' lines the tests
/// could run and ran.
struct CoverageReport: Decodable {
    let targets: [Target]

    /// The report in `json`, xccov's output, or nil if it can't be read.
    init?(json: Data) {
        guard let report = try? JSONDecoder().decode(Self.self, from: json) else {
            return nil
        }
        self = report
    }

    /// The binary of each product the coverage run built, the tests' among them. The build folder holds more: those of
    /// other run destinations, and of targets since removed, whose functions would read as never run at lines that now
    /// hold other code.
    var builtProducts: [String] {
        targets.compactMap(\.buildProductPath)
    }

    /// The derived data the coverage run used, the folder above `Build/Products` in its products' paths, which also
    /// holds the packages the project depends on, under `SourcePackages`, and the files the build generates.
    var derivedData: [String] {
        Set(builtProducts.compactMap { path in
            path.range(of: "/Build/Products/").map { String(path[..<$0.lowerBound]) }
        })
        .sorted()
    }

    /// The derived data the coverage run used: the folder above `Logs/Test` in `resultBundle`, the path of its result
    /// bundle, which also holds the run's profile, under `Build/ProfileData`, and then that of its products. Those of a
    /// Swift package whose folder isn't named after it are in other derived data, named after the folder, with the same
    /// hash, and no profile: `PkgProbe_mutated.noindex-<hash>` rather than `PkgProbe-<hash>`, as in SwiftMutator's copy
    /// of a project. `-resultBundlePath` moves the result bundle, and `SYMROOT` or `BUILD_DIR` the products, but
    /// neither moves the profile. So with `-resultBundlePath`, such a package's profile can't be found, unless
    /// `-derivedDataPath` puts all of it in one folder.
    func derivedData(resultBundle: String) -> [String] {
        let ofResultBundle = resultBundle.range(of: "/Logs/Test/")
            .map { [String(resultBundle[..<$0.lowerBound])] } ?? []
        return ofResultBundle + derivedData.exclude(ofResultBundle.contains)
    }

    /// The files the test targets build, which can be outside a `Tests` folder, as those of a package's test target
    /// with a `path` of its own are.
    var testFiles: [String] {
        targets.filter(\.isTest).flatMap(\.files).map(\.path)
    }

    struct Target: Decodable {
        let files: [CoverageReportFile]
        let name: String
        /// The binary built for the target, such as `…/AppTests.xctest/Contents/MacOS/AppTests`.
        let buildProductPath: String?

        /// Whether this is a test target, whose product is a `.xctest` bundle. xcodebuild names a package's test target
        /// without the `.xctest`, so only its build product shows it is one.
        var isTest: Bool {
            name.hasSuffix(".xctest") || buildProductPath?.contains(".xctest/") == true
        }
    }
}

extension [CoverageReport.Target] {
    func excludeTestTargets() -> [Element] {
        exclude(\.isTest)
    }
}
