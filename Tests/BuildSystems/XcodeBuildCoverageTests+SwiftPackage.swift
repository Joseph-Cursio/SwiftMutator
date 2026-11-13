@testable import muterCore
import TestingExtensions
import XCTest

extension XcodeBuildCoverageTests {
    // xccov lists a package's library with no files, and its tests with only theirs, though their bundle holds the
    // library's code. So the files, lines and regions all come from llvm-cov's export of that bundle, as on SwiftPM, in
    // this real run's, where `neverCalled()` and the files `Untested.swift` and `Other.swift` never ran. The library
    // has no binary of its own, and `-showBuildSettings` prints nothing for a package's scheme.
    func test_aPackage_getsItsCoverage_fromLLVMCovsExportOfItsTests() async throws {
        answerWithACoverageRun(report: packageReport, existing: [false, true, false], buildSettings: "") { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 20)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Calc/Untested.swift", "Sources/Other/Other.swift"])
        XCTAssertEqual(coverage.filesInCoverage, [
            "Sources/Calc/Calc.swift", "Sources/Calc/Untested.swift", "Sources/Other/Other.swift",
        ])
        let neverRun = coverage.functionsCoverage.regionsForFile("/project/Sources/Calc/Calc.swift")
        XCTAssertEqual(neverRun.map { [$0.lineStart, $0.lineEnd] }, [[5, 10], [6, 6], [6, 8], [8, 9]])
        XCTAssertNil(coverage.testsFailedWithCoverageOn)
        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }, [
            ["/usr/bin/xcrun", "llvm-cov", "export", packageTests, "-instr-profile", profile],
        ])
        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build"])
    }

    // Xcode builds the products of a package whose folder isn't named after it, as SwiftMutator's copy of a project
    // isn't, in derived data named after the folder, and keeps the result bundle and the profile in derived data named
    // after the package, with the same hash, as in this real run.
    func test_aPackagesProfile_isInTheDerivedDataOfItsResultBundle_notOfItsProducts() async throws {
        let products = "/DerivedData/PkgProbe_mutated-heuxeczqnwuysrfhawjcixylzvcq/Build/Products/Debug"
        let packageProfile = "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Build/ProfileData/MAC/"
            + "Coverage.profdata"
        answerWithACoverageRun(
            report: packageReport(in: products),
            existing: [false, true, false],
            log: "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Logs/Test/Test-PkgProbe.xcresult\n",
            buildSettings: "",
            profiles: [packageProfile + "\n", ""]
        ) { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let result = try await sut.run(with: muterConfiguration).get().percent
        XCTAssertEqual(result, 20)
        XCTAssertEqual(profilesLookedFor, [
            "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Build",
            "/DerivedData/PkgProbe_mutated-heuxeczqnwuysrfhawjcixylzvcq/Build",
        ])
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            products + "/CalcTests.xctest/Contents/MacOS/CalcTests",
            "-instr-profile", packageProfile,
        ])
    }

    // `-resultBundlePath` moves the result bundle out of the derived data, and `SYMROOT` or `BUILD_DIR` the products,
    // but neither moves the profile.
    func test_theDerivedData_isFoundFromEitherTheResultBundle_orTheProducts() async {
        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: ""
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build"])

        answerWithACoverageRun(
            report: packageReport(in: "/project/sym/Debug"),
            existing: [false, true, false],
            buildSettings: ""
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor.last, "/DerivedData/Build")
        XCTAssertEqual(profilesLookedFor.count, 2)
    }

    // With both moved, only `-showBuildSettings` can say where the build is, and for a package's scheme it says
    // nothing.
    func test_withNeitherInTheDerivedData_theProfile_isLookedForAboveBuildDir_ifThereIsOne() async throws {
        let report = packageReport(in: "/project/out/Debug")
        let testsExport: (([String]) -> CommandResult?) = { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }
        answerWithACoverageRun(
            report: report,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: "Build settings for action test and target CalcTests:\n    BUILD_DIR = /project/out\n",
            profiles: ["/project/ProfileData/MAC/Coverage.profdata\n"],
            export: testsExport
        )

        let percent = try await sut.run(with: muterConfiguration).get().percent
        XCTAssertEqual(percent, 20)
        XCTAssertEqual(profilesLookedFor, ["/project"])

        answerWithACoverageRun(
            report: report,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: "",
            profiles: [],
            export: testsExport
        )

        let withoutBuildDir = await sut.run(with: muterConfiguration)
        XCTAssertEqual(withoutBuildDir, .failure(.noXcodeBuildFolder))
        XCTAssertEqual(process.arguments, ["-showBuildSettings"])
        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }.count, 1, "llvm-cov ran without a build")
    }

    // With Xcode's Build Location set to Custom, relative to the workspace, as here, or to Shared Folder, the products
    // and the profile go with the build's intermediate files, and the result bundle stays in derived data, which can
    // hold the profile of a run from before the setting changed. The newest profile is the run's.
    func test_theNewestProfile_inAnyBuildFolder_isTheRuns() async {
        let fresh = "/project/Build/Intermediates.noindex/CodeCoverage/ProfileData/MAC/Coverage.profdata"
        let appBinary = "/project/Build/Products/Debug/App.app/Contents/MacOS/App"
        answerWithACoverageRun(
            report: report(
                target(
                    "App.app",
                    buildProductPath: appBinary,
                    files: [file("/project/App/Model.swift", executable: 4, covered: 2)]
                )
            ),
            existing: [true, false],
            buildSettings: "Build settings for action test and target App:\n    BUILD_DIR = /project/Build/Products\n",
            profiles: [profile + "\n", fresh + "\n", fresh + "\n" + profile + "\n"]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build", "/project/Build"])
        XCTAssertEqual(process.arguments, ["-t", profile, fresh])
        XCTAssertEqual(
            process.commandsRun.last,
            ["/usr/bin/xcrun", "llvm-cov", "export", appBinary, "-instr-profile", fresh]
        )
    }

    // A package's test target can have a `path` of its own, outside a `Tests` folder, and xccov names its files. Nor do
    // the files in derived data count, which `-derivedDataPath` can put in the project: those of the packages it
    // depends on, which its tests' bundle holds too, and those the build generates.
    func test_aPackagesTestFiles_andDerivedData_areLeftOut_whereverTheyAre() async throws {
        let derivedData = "/project/DerivedData"
        let tests = derivedData + "/Build/Products/Debug/CalcSpecs.xctest/Contents/MacOS/CalcSpecs"
        answerWithACoverageRun(
            report: report(
                target(
                    "CalcSpecs",
                    buildProductPath: tests,
                    files: [file("/project/Specs/CalcSpecs.swift", executable: 10, covered: 10)]
                )
            ),
            existing: [true, false],
            log: derivedData + "/Logs/Test/Test-PkgProbe.xcresult\n",
            buildSettings: "",
            profiles: [derivedData + "/Build/ProfileData/MAC/Coverage.profdata\n"]
        ) { _ in
            self.result(output: String(lossyUTF8: self.export(files: [
                self.exportedFile("/project/Sources/Calc/Calc.swift", count: 4, covered: 2),
                self.exportedFile("/project/Specs/CalcSpecs.swift", count: 10, covered: 10),
                self.exportedFile(
                    derivedData + "/SourcePackages/checkouts/Dep/Sources/Dep/Dep.swift",
                    count: 8,
                    covered: 0
                ),
                self.exportedFile(
                    derivedData + "/Build/Intermediates.noindex/Calc.build/Debug/Calc.build/DerivedSources/"
                        + "resource_bundle_accessor.swift",
                    count: 5,
                    covered: 0
                ),
            ])))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // The coverage of a run in which tests failed is kept, as an app's is, and they are named.
    func test_aPackagesFailedTests_keepItsCoverage_andAreNamed() async throws {
        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_testFailed.log"),
            status: 65,
            buildSettings: ""
        ) { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 20)
        XCTAssertEqual(
            coverage.testsFailedWithCoverageOn?.tests.map(\.name),
            ["sFails()", "-[ATests.ATests test_fails]"]
        )
    }

    // Without llvm-cov's export, a package has no coverage, as xccov's report says nothing of it, and the reason is
    // what kept the export from being had.
    func test_aPackageWhoseExportCantBeHad_givesNoCoverage_andSaysWhy() async {
        // Without a product, `find` never runs, and its answer is left for the next run, so that one comes last.
        typealias Export = ([String]) -> CommandResult?
        // Which paths exist, what `find` lists, how the export is answered, and the failure that gives.
        struct Run {
            let existing: [Bool]
            let profiles: [String]?
            let export: Export?
            let error: CoverageError
        }
        let runs = [
            Run(
                existing: [false, true, false],
                profiles: [""],
                export: nil,
                error: .noProfileData(atPath: "/DerivedData/Build")
            ),
            Run(existing: [false, true, false], profiles: nil, export: { _ in nil }, error: .couldNotRun("llvm-cov")),
            Run(
                existing: [false, true, false],
                profiles: nil,
                export: { _ in self.result(status: 1, errors: "error: malformed coverage data\n") },
                error: .llvmCovFailed("error: malformed coverage data")
            ),
            Run(
                existing: [false, true, false],
                profiles: nil,
                export: { _ in self.result(output: "not json") },
                error: .unreadableReport
            ),
            Run(existing: [false, true, false], profiles: nil, export: nil, error: .noProjectFiles),
            Run(existing: [false, false], profiles: nil, export: nil, error: .noBuiltProducts),
        ]

        for run in runs {
            answerWithACoverageRun(
                report: packageReport,
                existing: run.existing,
                buildSettings: "",
                profiles: run.profiles,
                export: run.export
            )

            let result = await sut.run(with: muterConfiguration)
            XCTAssertEqual(result, .failure(run.error))
        }
    }

    // Follow "Gathering coverage failed: ".
    func test_aPackagesOwnFailures_sayWhy() {
        XCTAssertEqual(
            CoverageError.noBuiltProducts.reason,
            "none of the products xccov says the coverage run built exists"
        )
        XCTAssertEqual(
            CoverageError.noXcodeBuildFolder.reason,
            "the coverage run's profile couldn't be found: its result bundle isn't in <DerivedData>/Logs/Test, "
                + "nor its products in <DerivedData>/Build/Products, "
                + "and xcodebuild -showBuildSettings gave no BUILD_DIR"
        )
        XCTAssertEqual(
            CoverageError.noProfileData(atPath: "/a/Build or /b/Build").reason,
            "there is no profile data at /a/Build or /b/Build"
        )
    }
}
