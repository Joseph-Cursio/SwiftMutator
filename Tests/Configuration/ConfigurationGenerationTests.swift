@testable import muterCore
import XCTest

final class ConfigurationGenerationTests: MuterTestCase {
    // The manifests need no `exclude`: the defaults always leave them out.
    func test_swiftPackageManagerProject() async throws {
        process.stdoutToBeReturned = which("swift")

        let generated = try await MuterConfiguration.generated(
            from: ["Package.swift", "Package@swift-5.11.swift", "Sources/App/main.swift"],
            in: "/some/path"
        )

        XCTAssertEqual(generated, GeneratedConfiguration(
            configuration: MuterConfiguration(executable: "/path/to/swift", arguments: ["test"]),
            scheme: nil
        ))
    }

    // Only a workspace or project at the top of the folder is the project's own: one below is an example app's, or a
    // dependency's in `.build/checkouts`, as `.swiftpm`'s workspace is SwiftPM's.
    func test_aPackageWithXcodeProjectsInFoldersBelow_isTestedAsAPackage() async throws {
        process.stdoutToBeReturned = which("swift")

        let generated = try await MuterConfiguration.generated(
            from: [
                ".build/checkouts/Dependency/Dependency.xcworkspace",
                ".swiftpm/xcode/package.xcworkspace",
                "Example/Demo.xcodeproj",
                "Package.swift",
            ],
            in: "/some/path"
        )

        XCTAssertEqual(generated.configuration.testCommandArguments, ["test"])
        XCTAssertEqual(process.processesRun, [["/usr/bin/which", "swift"]])
    }

    func test_unsupportedProject() async throws {
        let generated = try await MuterConfiguration.generated(from: ["main.swift"], in: "/some/path")

        XCTAssertEqual(generated, GeneratedConfiguration(configuration: MuterConfiguration(), scheme: nil))
    }

    // Two of the kind that wins can't be chosen between, so init writes nothing rather than test the wrong one.
    func test_severalWorkspaces_orSeveralProjects_areRefused() async {
        let cases: [(contents: [String], names: String)] = [
            (["B.xcworkspace", "A.xcworkspace", "A.xcodeproj"], "A.xcworkspace, B.xcworkspace"),
            (["Package.swift", "B.xcodeproj", "A.xcodeproj"], "A.xcodeproj, B.xcodeproj"),
        ]
        for (contents, names) in cases {
            let kind = names.hasSuffix("xcworkspace") ? "workspace" : "project"
            do {
                _ = try await MuterConfiguration.generated(from: contents, in: "/some/path")
                XCTFail("\(contents) wasn't refused")
            } catch {
                XCTAssertEqual(
                    "\(error)",
                    "There is more than one Xcode \(kind) in the project's folder (\(names)), and init can't tell "
                        + "which one runs your tests, so it wrote nothing. Write muter.conf.yml yourself: see "
                        + "Configuration in SwiftMutator's README."
                )
            }
        }
        XCTAssertEqual(process.processesRun, [])
    }

    // The scheme named after the workspace or project wins, then the only one, then the first; with none listed, the
    // name is a guess. Only a choice among several, or none, is said.
    func test_schemeChoice() {
        let named = SchemeChoice(listed: ["Pods-Shop", "Shop"], containerName: "Shop")
        XCTAssertEqual(named.chosen, "Shop")
        XCTAssertFalse(named.isAGuess)

        let only = SchemeChoice(listed: ["Delete Me Mac Os"], containerName: "CocoaApp")
        XCTAssertEqual(only.chosen, "Delete Me Mac Os")
        XCTAssertFalse(only.isAGuess)

        let first = SchemeChoice(listed: ["Core", "Shop App"], containerName: "Shop")
        XCTAssertEqual(first.chosen, "Core")
        XCTAssertTrue(first.isAGuess)

        let none = SchemeChoice(listed: [], containerName: "Shop")
        XCTAssertEqual(none.chosen, "Shop")
        XCTAssertTrue(none.isAGuess)
    }

    // xcodebuild can print a warning before the JSON.
    func test_schemesInListing() {
        XCTAssertEqual(
            MuterConfiguration.schemes(inListing: listing(schemes: ["App", "AppTests"])),
            ["App", "AppTests"]
        )
        XCTAssertEqual(
            MuterConfiguration.schemes(inListing: listing(schemes: ["Shop"], kind: "workspace")),
            ["Shop"]
        )
        XCTAssertEqual(MuterConfiguration.schemes(inListing: "xcodebuild: error: no such project"), [])
        XCTAssertEqual(MuterConfiguration.schemes(inListing: #"{ "project" : { "name" : "App" } }"#), [])
    }

    // Compared as names, iOS 9.3 came after iOS 18.2.
    func test_newestIOSRuntime_isComparedByVersion() {
        let runtimes = [
            "com.apple.CoreSimulator.SimRuntime.iOS-9-3",
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10",
            "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0",
        ]

        XCTAssertEqual(MuterConfiguration.newestIOSRuntime(among: runtimes), runtimes[1])
        XCTAssertNil(MuterConfiguration.newestIOSRuntime(among: ["com.apple.CoreSimulator.SimRuntime.tvOS-18-0"]))
    }

    #if !os(Linux)
    func test_iosProject() async throws {
        process.stdoutToBeReturned = listing(schemes: ["iOSApp"])
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["iOSApp.xcodeproj", "iOSApp.xcodeproj/project.pbxproj", "iOSApp/AppDelegate.swift"],
            in: xcodeProjectFiles
        )

        XCTAssertEqual(generated, GeneratedConfiguration(
            configuration: MuterConfiguration(
                executable: "/path/to/xcodebuild",
                arguments: [
                    "-project", "iOSApp.xcodeproj", "-scheme", "iOSApp",
                    "-destination", "platform=iOS Simulator,name=iPhone SE (3rd generation)", "test",
                ]
            ),
            scheme: SchemeChoice(listed: ["iOSApp"], containerName: "iOSApp")
        ))
        // The project is listed by its full path, as init can run in another folder.
        XCTAssertEqual(
            process.processesRun.first,
            ["/usr/bin/xcodebuild", "-project", "\(xcodeProjectFiles)/iOSApp.xcodeproj", "-list", "-json"]
        )
    }

    // The first generator that knows the project makes its configuration, so the package's, after it, doesn't run its
    // `which swift`. The project's own workspace, in the `.xcodeproj`, isn't a workspace of your own.
    func test_xcodeProjectBesideAPackage_winsOverIt() async throws {
        process.stdoutToBeReturned = listing(schemes: ["iOSApp"])
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["Package.swift", "iOSApp.xcodeproj", "iOSApp.xcodeproj/project.xcworkspace"],
            in: xcodeProjectFiles
        )

        XCTAssertEqual(generated.configuration.testCommandArguments.prefix(4), [
            "-project", "iOSApp.xcodeproj", "-scheme", "iOSApp",
        ])
        XCTAssertFalse(process.processesRun.contains(["/usr/bin/which", "swift"]), "\(process.processesRun)")
    }

    // The scheme is the one xcodebuild lists, not the project's name, and the destinations are those of that scheme.
    func test_macOSProject() async throws {
        process.stdoutToBeReturned = listing(schemes: ["Delete Me Mac Os"])
        process.stdoutToBeReturned = macOSDestinations()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(from: ["CocoaApp.xcodeproj"], in: xcodeProjectFiles)

        XCTAssertEqual(generated.configuration, MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project", "CocoaApp.xcodeproj", "-scheme", "Delete Me Mac Os",
                "-destination", "platform=macOS,arch=arm64,id=00006000-000A38D61E02401E,name=My Mac", "test",
            ]
        ))
        XCTAssertEqual(process.processesRun[1], [
            "/usr/bin/xcodebuild", "-project", "\(xcodeProjectFiles)/CocoaApp.xcodeproj", "-scheme", "Delete Me Mac Os",
            "-showdestinations",
        ])
    }

    // A workspace is named as it is, not after the project beside it, which says the platform.
    func test_workspace_isNamedAsItIs() async throws {
        process.stdoutToBeReturned = listing(schemes: ["Pods-Shop", "Shop"], kind: "workspace")
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["iOSApp.xcodeproj", "Shop.xcworkspace"],
            in: xcodeProjectFiles
        )

        XCTAssertEqual(generated.configuration.testCommandArguments, [
            "-workspace", "Shop.xcworkspace", "-scheme", "Shop",
            "-destination", "platform=iOS Simulator,name=iPhone SE (3rd generation)", "test",
        ])
        XCTAssertEqual(generated.scheme, SchemeChoice(listed: ["Pods-Shop", "Shop"], containerName: "Shop"))
    }

    // A workspace whose project is in a folder below: the project it names, through the group it is in, says the
    // platform.
    func test_workspaceWithItsProjectInAFolder_takesThePlatformFromTheProjectItNames() async throws {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            atPath: "\(directory)/Shop.xcworkspace",
            withIntermediateDirectories: true
        )
        // Xcode writes a project in a folder as a reference in a group of that folder.
        try """
        <Workspace version = "1.0">
           <Group location = "group:App" name = "App">
              <FileRef location = "group:App.xcodeproj"></FileRef>
           </Group>
        </Workspace>
        """
            .write(toFile: "\(directory)/Shop.xcworkspace/contents.xcworkspacedata", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(directory)/App", withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: "\(xcodeProjectFiles)/iOSApp.xcodeproj",
            toPath: "\(directory)/App/App.xcodeproj"
        )

        process.stdoutToBeReturned = listing(schemes: ["Shop"], kind: "workspace")
        process.stdoutToBeReturned = simCtl()
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["Shop.xcworkspace", "App/App.xcodeproj"],
            in: directory
        )

        XCTAssertEqual(
            generated.configuration.testCommandArguments.dropLast().last,
            "platform=iOS Simulator,name=iPhone SE (3rd generation)"
        )
    }

    // The newest iOS runtime's iPhone, by version.
    func test_iosProject_takesAnIPhoneOfTheNewestRuntime() async throws {
        process.stdoutToBeReturned = listing(schemes: ["iOSApp"])
        process.stdoutToBeReturned = """
        { "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-9-3": [
                { "isAvailable": true, "name": "iPhone 6s", "deviceTypeIdentifier": "iPhone-6s" }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
                { "isAvailable": true, "name": "iPhone 16", "deviceTypeIdentifier": "iPhone-16" }
            ]
        } }
        """
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(from: ["iOSApp.xcodeproj"], in: xcodeProjectFiles)

        XCTAssertEqual(
            generated.configuration.testCommandArguments.dropLast().last,
            "platform=iOS Simulator,name=iPhone 16"
        )
    }
    #endif

    var xcodeProjectFiles: String {
        "\(fixturesDirectory)/XcodeProjectFiles"
    }

    /// `xcodebuild -list -json`'s output, after a warning, as xcodebuild can print one.
    func listing(schemes: [String], kind: String = "project") -> String {
        let names = schemes.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        2026-11-12 10:00:00.000 xcodebuild[123:456] [MT] DVTAssertions: Warning in a plugin
        { "\(kind)" : { "name" : "App", "schemes" : [ \(names) ] } }
        """
    }

    func simCtl() -> String {
        """
        {
            "devicetypes":
            [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus",
                    "name": "iPhone 14 Plus"
                }
            ]
        }
        """
    }

    private func macOSDestinations() -> String {
        """
            [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.


                Available destinations for the "ExampleMacOSApp" scheme:
                    { platform:macOS, arch:arm64, id:00006000-000A38D61E02401E, name:My Mac }
                    { platform:macOS, name:Any Mac }
        """
    }

    func which(_ program: String) -> String {
        "/path/to/\(program)"
    }
}
