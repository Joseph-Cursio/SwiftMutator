import Foundation
@testable import muterCore
import TestingExtensions

extension SwiftCoverageTests {
    // Swift Build makes for each test target a runner that loads the target's tests, and with them its coverage
    // mapping, from a `.so` next to it. Neither the runners nor the libraries the tests link are read.
    func test_onLinux_eachTestTargetsLibrary_isExported_notItsRunner_orAnotherLibrary() async {
        answerWithACoverageRun(
            bundles: [
                "CoreTests.so", "CoreTests-test-runner", "AppTests.so", "AppTests-test-runner", "Core.so", "libCore.so",
            ],
            testTargets: ["CoreTests", "AppTests"],
            buildDirectory: linuxBuild
        )

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/env", "llvm-cov", "export",
            linuxBuild + "/AppTests.so", "-object", linuxBuild + "/CoreTests.so",
            "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [linuxBuild])
    }

    // A `.so` with no runner next to it holds no tests, even when the package's test targets are unknown, and the pair
    // of a test target the package no longer has is left out, as on macOS.
    func test_onLinux_aLibraryWithoutARunner_andAStaleTestTargetsPair_areLeftOut() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "Core.so", "libCore.so"],
            testTargets: nil,
            buildDirectory: linuxBuild
        )
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(2), [
            "export", linuxBuild + "/CoreTests.so", "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])

        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "OldTests.so", "OldTests-test-runner"],
            testTargets: ["CoreTests"],
            buildDirectory: linuxBuild
        )
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(2), [
            "export", linuxBuild + "/CoreTests.so", "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
    }

    // The native build system's one bundle, named after the package, is itself the executable on Linux.
    func test_onLinux_theNativeBuildSystemsBundle_isExportedAsItIs() async {
        let native = "/project/.build/x86_64-unknown-linux-gnu/debug"
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest", "Core.build"], buildDirectory: native)

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/env", "llvm-cov", "export", native + "/ProjectPackageTests.xctest",
            "-instr-profile", native + "/codecov/default.profdata",
        ])
    }

    // SwiftPM takes the llvm-cov next to the toolchain's `swiftc`. One from elsewhere on PATH, such as a
    // distribution's, may not read the toolchain's profiles.
    func test_onLinux_llvmCov_isTheOneNextToTheTestCommand_whenThereIsOne() async throws {
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, true]

        let coverage = try await onLinux.run(with: muterConfiguration).get()

        XCTAssertEqual(process.commandsRun.last, [
            "/path/to/llvm-cov", "export", linuxBuild + "/CoreTests.so",
            "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [linuxBuild + "/codecov/default.profdata", "/path/to/llvm-cov"])
        XCTAssertEqual(coverage.percent, 50)
    }

    func test_onLinux_llvmCov_isTheOneOnThePath_whenNoneIsNextToTheTestCommand() async {
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, false]

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.prefix(3), ["/usr/bin/env", "llvm-cov", "export"])
        XCTAssertEqual(fileManager.fileExistsAtPath.last, "/path/to/llvm-cov")
    }

    // `/usr/bin/swift` is often a link into the toolchain, whose folder holds the LLVM tools.
    func test_onLinux_theLLVMTools_areLookedFor_whereTheTestCommandsLinkLeads() async throws {
        let directory = try makeTemporaryDirectory().canonicalPath
        let toolchain = directory + "/toolchain/usr/bin"
        try FileManager.default.createDirectory(atPath: toolchain, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: toolchain + "/swift", contents: nil)
        try FileManager.default.createSymbolicLink(
            atPath: directory + "/swift",
            withDestinationPath: toolchain + "/swift"
        )
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, true]

        _ = await onLinux.run(with: MuterConfiguration(executable: directory + "/swift", arguments: ["test"]))

        XCTAssertEqual(process.commandsRun.last?.first, toolchain + "/llvm-cov")
        XCTAssertEqual(fileManager.fileExistsAtPath.last, toolchain + "/llvm-cov")
    }

    // The merge after a failed test looks for llvm-profdata the same way.
    func test_onLinux_theMerge_usesTheLLVMProfdataNextToTheTestCommand_orElseTheOneOnThePath() async {
        let codecov = linuxBuild + "/codecov"
        let merge = ["merge", "-sparse", codecov + "/XCTest1234_0.501.profraw", "-o", codecov + "/default.profdata"]
        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "XCTest1234_0.501.profraw"],
            buildDirectory: linuxBuild,
            testRun: result(status: 1, output: failedTestsOutput)
        )

        fileManager.fileExistsToReturn = [true, true]
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last { $0.contains("merge") }, ["/path/to/llvm-profdata"] + merge)
        XCTAssertEqual(fileManager.fileExistsAtPath.first, "/path/to/llvm-profdata")

        fileManager.fileExistsToReturn = [false, true]
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(
            process.commandsRun.last { $0.contains("merge") },
            ["/usr/bin/env", "llvm-profdata"] + merge
        )
    }

    func test_theHostPlatform_isTheOneSwiftMutatorWasBuiltFor() {
        #if os(Linux)
        XCTAssertEqual(SwiftCoverage.Platform.host, .linux)
        #else
        XCTAssertEqual(SwiftCoverage.Platform.host, .darwin)
        #endif
    }
}
