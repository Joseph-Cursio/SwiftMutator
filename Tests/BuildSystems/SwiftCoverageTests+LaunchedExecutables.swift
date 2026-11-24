@testable import muterCore
import XCTest

/// The package's executables that the tests ran as processes, exported with the test bundles.
extension SwiftCoverageTests {
    // Tool's own file ran, so a test started it; Example shares Core with the bundle, whose counts it has too, but its
    // own file didn't run, so nothing started it and its files stay out, rather than counting as never run.
    func test_anExecutableWhoseOwnFilesRan_isExportedWithTheBundles() async throws {
        answerWithExecutables(summary: [
            file("/project/Sources/Core/Shared.swift", count: 6, covered: 4),
            file("/project/Sources/Tool/main.swift", count: 3, covered: 3),
            file("/project/Sources/ToolKit/ToolKit.swift", count: 4, covered: 1),
            file("/project/Sources/Example/main.swift", count: 2, covered: 0),
        ])

        _ = await sut.run(with: muterConfiguration)

        // The tested package alone is described: its local package names neither test targets nor executables.
        XCTAssertEqual(process.commandsRun.filter { $0.contains("describe") }.count, 1)
        let exports = process.commandsRun.filter { $0.contains("llvm-cov") }
        XCTAssertEqual(exports, [
            [
                "/usr/bin/xcrun", "llvm-cov", "export", "-summary-only", bundle("CoreTests"),
                "-object", products + "/Example", "-object", products + "/Tool",
                "-instr-profile", products + "/codecov/default.profdata",
            ],
            [
                "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"), "-object", products + "/Tool",
                "-instr-profile", products + "/codecov/default.profdata",
            ],
        ])
    }

    // An executable the build didn't make can't be read, and llvm-cov fails for an object that isn't there.
    func test_anExecutableTheBuildDidntMake_isLeftOut() async throws {
        answerWithExecutables(
            summary: [file("/project/Sources/Tool/main.swift", count: 3, covered: 3)],
            built: [false, true]
        )

        _ = await sut.run(with: muterConfiguration)

        let summary = try XCTUnwrap(process.commandsRun.first { $0.contains("-summary-only") })
        XCTAssertFalse(summary.contains(products + "/Example"))
        XCTAssertTrue(summary.contains(products + "/Tool"))
    }

    // The bundles' coverage stands when the executables' can't be read.
    func test_whenTheExecutablesExportFails_theBundlesAloneAreExported() async throws {
        answerWithExecutables(summary: nil)

        let result = await sut.run(with: muterConfiguration)

        XCTAssertNotNil(try? result.get())
        let export = try XCTUnwrap(process.commandsRun.last)
        XCTAssertEqual(export, [
            "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"),
            "-instr-profile", products + "/codecov/default.profdata",
        ])
    }

    // `--test-product` builds that product alone, so an executable in the build folder may be left from another build.
    func test_whenTheTestCommandBuildsOneTestProduct_noExecutableIsExported() async {
        answerWithExecutables(summary: [file("/project/Sources/Tool/main.swift", count: 3, covered: 3)])
        muterConfiguration = MuterConfiguration(
            executable: "/path/to/swift",
            arguments: ["test", "--test-product", "X"]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }.count, 1)
        XCTAssertFalse(process.commandsRun.contains { $0.contains(products + "/Tool") })
    }

    // describe lists a target's files with the links in their folders resolved, and llvm-cov names them by the folder
    // SwiftPM was given, here a link; a tool in a `Tests` folder, as a fixture's is, is no test file here either.
    func test_anExecutableInALinkedFolder_orATestsFolder_isMatchedByItsOwnFiles() async throws {
        let (directory, _) = try makeDirectoryWithSymbolicLink()
        let root = directory.canonicalPath
        for folder in ["Sources/Real", "Tests/Fixtures/Echo"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/" + folder + "/main.swift", contents: Data())
        }
        try FileManager.default.createSymbolicLink(atPath: root + "/Sources/Tool", withDestinationPath: "Real")
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        fileManager.currentDirectoryPathToReturn = root
        fileManager.fileExistsToReturn = [true, true, true]
        let description = #"{"name": "P", "path": "\#(root)", "dependencies": [], "products": ["#
            + #"{"name": "Echo", "targets": ["Echo"]}, {"name": "Tool", "targets": ["Tool"]}], "targets": ["#
            + #"{"name": "CoreTests", "type": "test", "path": "Tests/CoreTests", "sources": []}, "#
            + #"{"name": "Echo", "type": "executable", "path": "Tests/Fixtures/Echo", "sources": ["main.swift"]}, "#
            + #"{"name": "Tool", "type": "executable", "path": "Sources/Tool", "sources": ["main.swift"]}]}"#
        let summary = String(lossyUTF8: export(files: [
            file(root + "/Sources/Tool/main.swift", count: 3, covered: 3),
            file(root + "/Tests/Fixtures/Echo/main.swift", count: 2, covered: 2),
        ]))
        let answer = process.commandResult
        process.commandResult = { command in
            if command.contains("describe") {
                return self.result(output: description)
            }
            return command.contains("-summary-only") ? self.result(output: summary) : answer(command)
        }

        _ = await sut.run(with: muterConfiguration)

        let export = try XCTUnwrap(process.commandsRun.last)
        XCTAssertEqual(Array(export.suffix(6)), [
            "-object", products + "/Echo", "-object", products + "/Tool",
            "-instr-profile", products + "/codecov/default.profdata",
        ])
    }

    // A package with no executable makes no extra export.
    func test_withoutAnExecutable_thereIsNoExtraExport() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }.count, 1)
    }

    // MARK: - Helpers

    private var products: String {
        "/project/.build/out/Products/Debug"
    }

    /// Answers a coverage run of a package whose `CoreTests` test Core, with two executables, Tool, which links
    /// ToolKit, and Example, both built unless `built` says otherwise, in product name order. The export with them
    /// gives `summary`'s files, or fails when it is nil; the export of what ran gives `exportJSON`.
    private func answerWithExecutables(summary: [String]?, built: [Bool] = [true, true]) {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        fileManager.fileExistsToReturn = [true] + built
        let targets = [
            #"{"name": "CoreTests", "type": "test", "path": "Tests/CoreTests", "sources": ["CoreTests.swift"], "#
                + #""target_dependencies": ["Core"]}"#,
            #"{"name": "Core", "type": "library", "path": "Sources/Core", "sources": ["Shared.swift"]}"#,
            #"{"name": "Tool", "type": "executable", "path": "Sources/Tool", "sources": ["main.swift"], "#
                + #""target_dependencies": ["ToolKit"]}"#,
            #"{"name": "ToolKit", "type": "library", "path": "Sources/ToolKit", "sources": ["ToolKit.swift"]}"#,
            #"{"name": "Example", "type": "executable", "path": "Sources/Example", "sources": ["main.swift"], "#
                + #""target_dependencies": ["Core"]}"#,
        ]
        let productEntries = [
            #"{"name": "Tool", "type": {"executable": null}, "targets": ["Tool"]}"#,
            #"{"name": "Example", "type": {"executable": null}, "targets": ["Example"]}"#,
        ]
        let dependency = #"{"identity": "core", "path": "/project/Packages/Core", "type": "fileSystem"}"#
        let description = #"{"name": "Project", "path": "/project", "dependencies": [\#(dependency)], "#
            + #""products": [\#(productEntries.joined(separator: ","))], "#
            + #""targets": [\#(targets.joined(separator: ","))]}"#
        let summaryExport = summary.map { String(lossyUTF8: export(files: $0)) }
        let answer = process.commandResult
        process.commandResult = { command in
            if command.contains("describe") {
                return self.result(output: description)
            }
            if command.contains("-summary-only") {
                return summaryExport.map { self.result(output: $0) } ?? self.result(status: 1, errors: "error: no")
            }
            return answer(command)
        }
    }
}
