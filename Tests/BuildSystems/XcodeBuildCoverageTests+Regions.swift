@testable import muterCore
import TestingExtensions
import XCTest

extension XcodeBuildCoverageTests {
    // xccov's report has no regions, so which code no test ran comes from llvm-cov's export.
    func test_functionCoverage() async throws {
        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [true, false, false])

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(
            coverage.functionsCoverage.regionsForFile("/path/to/file.swift"), [
                .make(
                    lineStart: 14,
                    columnStart: 80,
                    lineEnd: 24,
                    columnEnd: 4,
                    executionCount: 0
                ),
            ]
        )
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            "/DerivedData/Build/Products/Debug/Project.framework/Versions/A/Project",
            "-instr-profile", profile,
        ])
    }

    // Hosted tests and UI tests run the app's code, which only the app's binary maps, and each test bundle maps only
    // the code linked into it. So one export reads every product the run built: the first by name, then each other as
    // an object.
    func test_everyProductTheRunBuilt_isExported_inOneCall() async {
        answerWithACoverageRun(report: appReport, existing: [true, false, true, false, true, false])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.count, 2)
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            app, "-object", appTests, "-object", appUITests,
            "-instr-profile", profile,
        ])
    }

    // In a Debug build, an app's executable only loads `<App>.debug.dylib`, which holds the app's code.
    func test_anAppsDebugDylib_isExported_afterTheApp() async {
        answerWithACoverageRun(report: appReport, existing: [true, true, true, false, true, false])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).prefix(5), [
            app, "-object", app + ".debug.dylib", "-object", appTests,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [
            app, app + ".debug.dylib", appTests, appTests + ".debug.dylib", appUITests, appUITests + ".debug.dylib",
        ])
    }

    // xccov lists a package's library as a framework that isn't built when the library is linked into its tests, and
    // llvm-cov fails on a file that doesn't exist.
    func test_aProductThatDoesntExist_isLeftOut() async {
        let library = debug + "/PackageFrameworks/Core_3124CAE0_PackageProduct.framework/Core_3124CAE0_PackageProduct"
        let tests = debug + "/CoreTests.xctest/Contents/MacOS/CoreTests"
        answerWithACoverageRun(
            report: report(
                target(
                    "Core",
                    buildProductPath: library,
                    files: [file("/project/Core/Parser.swift", executable: 4, covered: 2)]
                ),
                target("CoreTests", buildProductPath: tests, files: [])
            ),
            existing: [false, true, false]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", tests, "-instr-profile", profile,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [library, tests, tests + ".debug.dylib"])
    }

    // xccov's report of an app can leave out a local package the app links, whose code llvm-cov's export of the app
    // maps; and the export, the code of a target whose binary isn't where xccov says. So the files in coverage are
    // those either names, but for test files and those outside the project.
    func test_theFilesInCoverage_areThoseXccovOrLLVMCovNames() async throws {
        answerWithACoverageRun(
            report: report(
                target(
                    "App.app",
                    buildProductPath: app,
                    files: [file("/project/App/Model.swift", executable: 10, covered: 5)]
                ),
                target("Widget.appex", files: [file("/project/Widget/Widget.swift", executable: 4, covered: 0)]),
                target("AppTests.xctest", buildProductPath: appTests, files: [
                    file("/project/AppTests/ModelChecks.swift", executable: 8, covered: 8),
                ])
            ),
            existing: [true, false, true, false]
        ) { _ in
            self.result(output: String(lossyUTF8: self.export(files: [
                self.exportedFile("/project/App/Model.swift", count: 10, covered: 5),
                self.exportedFile("/project/Packages/Core/Sources/Core/Parser.swift", count: 6, covered: 3),
                self.exportedFile("/project/AppTests/ModelChecks.swift", count: 8, covered: 8),
                self.exportedFile("/DerivedData/SourcePackages/checkouts/Dep/Sources/Dep.swift", count: 3, covered: 0),
            ])))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.filesInCoverage, [
            "App/Model.swift", "Packages/Core/Sources/Core/Parser.swift", "Widget/Widget.swift",
        ])
    }

    // Without regions, xccov's lines still say which files no test ran: when llvm-cov fails, or no product it lists
    // exists.
    func test_withoutRegions_xccovsCoverageIsStillGiven() async throws {
        let xccovs = Coverage.make(percent: 10, filesWithoutCoverage: ["Sources/file1.swift"])
        answerWithACoverageRun(
            report: Data(coverageData.utf8),
            existing: [true, false, false]
        ) { _ in self.result(status: 1, errors: "error: failed to load coverage: 'Project': No such file\n") }

        let whenLLVMCovFails = try await sut.run(with: muterConfiguration).get()
        XCTAssertEqual(whenLLVMCovFails, xccovs)
        // xccov's report alone can leave out files the binaries hold, so discovery leaves none out for this.
        XCTAssertNil(whenLLVMCovFails.filesInCoverage)
        XCTAssertEqual(process.commandsRun.last?.prefix(3), ["/usr/bin/xcrun", "llvm-cov", "export"])

        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [false, false])

        let withoutAProduct = try await sut.run(with: muterConfiguration).get()
        XCTAssertEqual(withoutAProduct, xccovs)
        XCTAssertEqual(process.commandsRun.count, 3, "llvm-cov ran without a product")
    }

    // A build for every architecture, as `ONLY_ACTIVE_ARCH=NO` makes, gives universal binaries, which llvm-cov reads
    // only for an architecture named, as in this real export, where it warned first. This Mac's is named then, not
    // from the start: llvm-cov would then fail for a binary built only for another, as for an Intel Mac's destination.
    func test_aUniversalBinary_isReadForThisMacsArchitecture() async throws {
        let armCoverage = XcodeBuildCoverage(architecture: "arm64")
        let universal = result(status: 1, errors: """
        warning: App: profile data may be out of date - object is newer
        error: failed to load coverage: 'App.debug.dylib': `-arch` specifier is invalid or missing for universal binary
        error: could not load coverage information

        """)
        answerWithACoverageRun(report: appReport, existing: [true, true, false, false]) { command in
            command.contains("-arch") ? self.result(output: self.loadFixture("llvmCovExport.json")) : universal
        }

        let coverage = try await armCoverage.run(with: muterConfiguration).get()

        let export = [
            "/usr/bin/xcrun", "llvm-cov", "export", app, "-object", app + ".debug.dylib", "-instr-profile", profile,
        ]
        XCTAssertEqual(process.commandsRun.suffix(2), [export, export + ["-arch", "arm64"]])
        XCTAssertEqual(coverage.functionsCoverage.regionsForFile("/path/to/file.swift").count, 1)
    }

    // Why llvm-cov failed is the first line that says so, not a warning before it.
    func test_whyLLVMCovFailed_isItsFirstError() async {
        process.commandResult = { _ in
            self.result(
                status: 1,
                errors: "warning: 2 functions have mismatched data\nerror: malformed coverage data\n"
            )
        }

        let result = await sut.llvmCovExport(of: [app], profile: profile, llvmCov: ("/usr/bin/xcrun", ["llvm-cov"]))
        XCTAssertEqual(
            result,
            .failure(.llvmCovFailed("error: malformed coverage data"))
        )
    }
}
