@testable import muterCore
import XCTest

/// Which targets' files discovery picks from: those a test can run (`SwiftPackageSources.reachedByTheTests(_:)`).
extension SwiftPackageSourcesTests {
    // A test target's dependencies, and theirs in turn, can run in a test; so can an executable target, which a test
    // can run as a process, and what it depends on. An example or an unused target can't.
    func test_aTargetNoTestReaches_isLeftOut() async {
        describing([
            "/project": [
                target("test", path: "Tests/AppTests", sources: ["AppTests.swift"], dependsOn: ["App", "TestSupport"]),
                target("library", path: "Tests/TestSupport", sources: ["Support.swift"], dependsOn: ["Fixtures"]),
                target("library", path: "Sources/Fixtures", sources: ["Fixtures.swift"]),
                target("library", path: "Sources/App", sources: ["App.swift"], dependsOn: ["Model"]),
                target("library", path: "Sources/Model", sources: ["Model.swift"]),
                target("executable", path: "Sources/Tool", sources: ["main.swift"], dependsOn: ["ToolKit"]),
                target("library", path: "Sources/ToolKit", sources: ["ToolKit.swift"]),
                target("library", path: "Sources/Unused", sources: ["Unused.swift"]),
                target("library", path: "Examples/Demo", sources: ["Demo.swift"], dependsOn: ["App"]),
            ],
        ])

        let result = await files(in: "/project")
        XCTAssertEqual(result, .success([
            "Sources/App/App.swift",
            "Sources/Fixtures/Fixtures.swift",
            "Sources/Model/Model.swift",
            "Sources/Tool/main.swift",
            "Sources/ToolKit/ToolKit.swift",
            "Tests/TestSupport/Support.swift",
        ]))
    }

    // A product names no package, so it is looked for among the local packages' products; one that none has is a
    // remote package's. A local package the tests don't reach is still described, as build conditions need every one,
    // but its files aren't listed, nor are a reached package's targets that its product doesn't hold.
    func test_aLocalPackagesTargets_areReachedThroughItsProducts() async {
        describing(
            [
                "/project": [
                    target("test", path: "Tests/AppTests", sources: ["AppTests.swift"], dependsOn: ["App"]),
                    target("library", path: "Sources/App", sources: ["App.swift"], products: ["Core", "Remote"]),
                ],
                "/project/Packages/Core": [
                    target("library", path: "Sources/Core", sources: ["Core.swift"], dependsOn: ["CoreBase"]),
                    target("library", path: "Sources/CoreBase", sources: ["Base.swift"], products: ["Util"]),
                    target("library", path: "Sources/CoreExtras", sources: ["Extras.swift"]),
                    target("test", path: "Tests/CoreTests", sources: ["CoreTests.swift"], dependsOn: ["CoreExtras"]),
                ],
                "/project/Packages/Util": [target("library", path: "Sources/Util", sources: ["Util.swift"])],
                "/project/Packages/Unreached": [target("library", path: "Sources/Lone", sources: ["Lone.swift"])],
            ],
            dependencies: [
                "/project": ["/project/Packages/Core", "/project/Packages/Unreached", nil],
                "/project/Packages/Core": ["/project/Packages/Util"],
            ],
            products: [
                "/project/Packages/Core": ["Core": ["Core"], "CoreExtras": ["CoreExtras"]],
                "/project/Packages/Util": ["Util": ["Util"]],
                "/project/Packages/Unreached": ["Lone": ["Lone"]],
            ]
        )

        let result = await files(in: "/project")
        XCTAssertEqual(result, .success([
            "Packages/Core/Sources/Core/Core.swift",
            "Packages/Core/Sources/CoreBase/Base.swift",
            "Packages/Util/Sources/Util/Util.swift",
            "Sources/App/App.swift",
        ]))
        XCTAssertEqual(process.commandsRun.compactMap { $0.dropFirst(3).first }.sorted(), [
            "/project", "/project/Packages/Core", "/project/Packages/Unreached", "/project/Packages/Util",
        ])
    }

    // What its tests reach can't be told then, so nothing is left out for it.
    func test_withoutATestTarget_everyTargetIsListed() async {
        describing([
            "/project": [
                target("library", path: "Sources/App", sources: ["App.swift"]),
                target("library", path: "Sources/Unused", sources: ["Unused.swift"]),
            ],
        ])

        let result = await files(in: "/project")
        XCTAssertEqual(result, .success(["Sources/App/App.swift", "Sources/Unused/Unused.swift"]))
    }

    // Describe lists a dependency in a `.when(platforms:)` condition whatever the platform, so its target is kept.
    func test_aConditionalDependency_isFollowed() {
        let packages = [
            SwiftPackageSources.Package(
                path: "/project",
                targets: [
                    .init(name: "App", files: ["Sources/App/App.swift"], targetDependencies: ["LinuxShim"]),
                    .init(name: "LinuxShim", files: ["Sources/LinuxShim/Shim.swift"]),
                ],
                testTargets: [.init(name: "AppTests", files: [], type: "test", targetDependencies: ["App"])]
            ),
        ]

        XCTAssertEqual(
            SwiftPackageSources.reachedByTheTests(packages).compactMap(\.name),
            ["App", "LinuxShim"]
        )
    }
}
