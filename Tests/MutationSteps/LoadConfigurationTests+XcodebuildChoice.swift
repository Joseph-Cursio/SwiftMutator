@testable import muterCore
import XCTest

/// #262: the `workspace`, `project`, `scheme` and `destination` keys, and their flags, merged into `arguments`.
extension LoadConfigurationTests {
    private var xcodebuild: String {
        "executable: /usr/bin/xcodebuild\n"
    }

    // A flag replaces its key and every occurrence of its option, so a key that disagrees with arguments is let
    // through; the keys are then cleared, so the header records arguments alone.
    func test_eachFlag_replacesItsOptionInArguments_andItsKey() async throws {
        let configuration = try await loaded(
            xcodebuild + """
            arguments: [-project, Old.xcodeproj, -scheme, Old, -destination, platform=macOS, -quiet,
                        -destination, 'platform=iOS Simulator,name=X', test]
            project: Old.xcodeproj
            scheme: Key
            destination: id=0
            """,
            flags: XcodebuildChoice(workspace: "New.xcworkspace", scheme: "New", destinations: ["id=1", "id=2"])
        )

        XCTAssertEqual(configuration.testCommandArguments, [
            "-workspace", "New.xcworkspace", "-scheme", "New", "-destination", "id=1", "-destination", "id=2",
            "-quiet", "test",
        ])
        XCTAssertEqual(configuration.xcodebuild, XcodebuildChoice())
    }

    // The container and the scheme go at the front, the scheme after any container; the destinations before the
    // first action, or at the end without one.
    func test_aKey_isAddedWhereArgumentsLackItsOption() async throws {
        let added = try await loaded(xcodebuild + """
        arguments: [-skipMacroValidation, test, -only-testing:AppTests]
        workspace: App.xcworkspace
        scheme: App
        destination: [id=1, id=2]
        """)
        XCTAssertEqual(added.testCommandArguments, [
            "-workspace", "App.xcworkspace", "-scheme", "App", "-skipMacroValidation", "-destination", "id=1",
            "-destination", "id=2", "test", "-only-testing:AppTests",
        ])

        let afterTheProject = try await loaded(xcodebuild + """
        arguments: [-project, App.xcodeproj, -configuration, Debug, -destination, id=1]
        scheme: App
        """)
        XCTAssertEqual(afterTheProject.testCommandArguments, [
            "-project", "App.xcodeproj", "-scheme", "App", "-configuration", "Debug", "-destination", "id=1",
        ])

        let atTheEnd = try await loaded(xcodebuild + "arguments: [-scheme, test]\ndestination: id=1\n")
        XCTAssertEqual(atTheEnd.testCommandArguments, ["-scheme", "test", "-destination", "id=1"])
    }

    // The same value is no clash: arguments keep their spelling and place. Paths compare in the project's folder,
    // destinations by their key=value pairs, in any order.
    func test_aKeyThatArgumentsAgreeWith_leavesThemAsTheyAre() async throws {
        let arguments = [
            "-workspace", "./App.xcworkspace", "-scheme", "App", "-destination",
            "platform=iOS Simulator, name=iPhone 17", "test",
        ]
        let configuration = try await loaded(xcodebuild + """
        arguments: [-workspace, ./App.xcworkspace, -scheme, App, -destination, 'platform=iOS Simulator, name=iPhone 17',
                    test]
        workspace: App.xcworkspace/
        scheme: App
        destination: name=iPhone 17,platform=iOS Simulator
        """)

        XCTAssertEqual(configuration.testCommandArguments, arguments)
    }

    // The run can't tell which is meant, so it says both.
    func test_aKeyThatDisagreesWithArguments_isRefused_namingBoth() async {
        let refused = [
            (
                "arguments: [-scheme, Other, -destination, id=1, test]\nscheme: App",
                "`scheme: App` and `-scheme Other` in `arguments` name different schemes: give it once, in `scheme:` "
                    + "or in `arguments`."
            ),
            (
                "arguments: [-scheme, App, -destination, 'platform=iOS Simulator,name=X', test]\n"
                    + "destination: platform=macOS",
                "`destination: platform=macOS` and `-destination platform=iOS Simulator,name=X` in `arguments` name "
                    + "different destinations: give them once, in `destination:` or in `arguments`."
            ),
            (
                "arguments: [-destination, id=2, -destination, id=1, test]\ndestination: [id=1, id=2]",
                "`destination:`'s 2 destinations and `-destination id=2 -destination id=1` in `arguments` name "
                    + "different destinations: give them once, in `destination:` or in `arguments`."
            ),
            (
                "arguments: [-workspace, B.xcworkspace, -destination, id=1, test]\nworkspace: A.xcworkspace",
                "`workspace: A.xcworkspace` and `-workspace B.xcworkspace` in `arguments` name different workspaces: "
                    + "give it once, in `workspace:` or in `arguments`."
            ),
            (
                "arguments: [-project, App.xcodeproj, -destination, id=1, test]\nworkspace: App.xcworkspace",
                "`workspace: App.xcworkspace` and `-project App.xcodeproj` in `arguments` name a workspace and a "
                    + "project, and xcodebuild opens one: give it once, in `workspace:` or in `arguments`."
            ),
            (
                "arguments: [-workspace, App.xcworkspace, -destination, id=1, test]\nproject: App.xcodeproj",
                "`project: App.xcodeproj` and `-workspace App.xcworkspace` in `arguments` name a workspace and a "
                    + "project, and xcodebuild opens one: give it once, in `project:` or in `arguments`."
            ),
            (
                "arguments: [-destination, id=1, test]\nworkspace: App.xcworkspace\nproject: App.xcodeproj",
                "`workspace:` and `project:` can't both be given: xcodebuild opens one workspace or project."
            ),
        ]
        for (yaml, reason) in refused {
            await assertXcodebuildChoiceRefused(xcodebuild + yaml, reason)
        }
    }

    // It would open the project, not the copy SwiftMutator mutates.
    func test_aWorkspaceOrProjectNamedByAnAbsolutePath_isRefused() async {
        await assertXcodebuildChoiceRefused(
            xcodebuild + "arguments: [-destination, id=1, test]\nworkspace: /Users/me/App/App.xcworkspace",
            "`workspace: /Users/me/App/App.xcworkspace` is an absolute path: name it relative to the project's "
                + "folder, as App.xcworkspace, so the run opens the one in the copy SwiftMutator mutates."
        )
        await assertXcodebuildChoiceRefused(
            xcodebuild + "arguments: [-destination, id=1, test]",
            "`--project ~/App/App.xcodeproj` is an absolute path: name it relative to the project's folder, as "
                + "App.xcodeproj, so the run opens the one in the copy SwiftMutator mutates.",
            flags: XcodebuildChoice(project: "~/App/App.xcodeproj")
        )
    }

    // A relative path that climbs out of the project's folder opens the project too, even one that comes back into a
    // folder of the project's name, as the copy has another; one that stays below it is fine.
    func test_aWorkspaceOrProjectOutsideTheProjectsFolder_isRefused() async throws {
        fileManager.currentDirectoryPathToReturn = "/some/App"
        await assertXcodebuildChoiceRefused(
            xcodebuild + "arguments: [-destination, id=1, test]",
            "`--workspace ../App/App.xcworkspace` names one outside the project's folder: name it relative to the "
                + "project's folder, as App.xcworkspace, so the run opens the one in the copy SwiftMutator mutates.",
            flags: XcodebuildChoice(workspace: "../App/App.xcworkspace")
        )
        await assertXcodebuildChoiceRefused(
            xcodebuild + "arguments: [-destination, id=1, test]",
            "`--workspace ../Other/App.xcworkspace` names one outside the project's folder: name it relative to the "
                + "project's folder, as App.xcworkspace, so the run opens the one in the copy SwiftMutator mutates.",
            flags: XcodebuildChoice(workspace: "../Other/App.xcworkspace")
        )
        await assertXcodebuildChoiceRefused(
            xcodebuild + "arguments: [-destination, id=1, test]\nproject: ../App.xcodeproj",
            "`project: ../App.xcodeproj` names one outside the project's folder: name it relative to the project's "
                + "folder, as App.xcodeproj, so the run opens the one in the copy SwiftMutator mutates."
        )

        let below = try await loaded(
            xcodebuild + "arguments: [-destination, id=1, test]\nproject: Apps/../App.xcodeproj"
        )
        XCTAssertEqual(
            below.testCommandArguments,
            ["-project", "Apps/../App.xcodeproj", "-destination", "id=1", "test"]
        )
    }

    // `swift test` has none of them, and a wrapper script is xcodebuild only with `buildSystem: xcodebuild`.
    func test_aTestCommandThatIsntXcodebuild_isRefused() async {
        await assertXcodebuildChoiceRefused(
            "executable: /usr/bin/swift\narguments: [test]\nscheme: App",
            "`scheme:` is for an xcodebuild project: `swift test` has no scheme, destination, workspace or project."
        )
        await assertXcodebuildChoiceRefused(
            "executable: /usr/local/bin/run-tests.sh\narguments: [test]",
            "`--destination` is for an xcodebuild project, and `executable` isn't xcodebuild: set "
                + "`buildSystem: xcodebuild` if it runs xcodebuild.",
            flags: XcodebuildChoice(destinations: ["platform=macOS"])
        )
    }

    func test_aWrapperScriptWithBuildSystemXcodebuild_getsTheKeysMerged() async throws {
        let configuration = try await loaded("""
        executable: /usr/local/bin/run-tests.sh
        buildSystem: xcodebuild
        arguments: [--wrapper-flag, test]
        scheme: App
        destination: platform=macOS
        """)

        XCTAssertEqual(
            configuration.testCommandArguments,
            ["-scheme", "App", "--wrapper-flag", "-destination", "platform=macOS", "test"]
        )
    }

    // The check for a destination sees the merged arguments, and says where one can come from.
    func test_aDestinationKey_orFlag_givesTheDestinationTheRunNeeds() async throws {
        let withoutDestination = try XCTUnwrap(loadYAMLConfigurationWithoutDestination())
        await assertXcodebuildChoiceRefused(
            String(lossyUTF8: withoutDestination),
            "Give xcodebuild a destination to test on: `destination:` in the configuration, `--destination`, or "
                + "`-destination` in `arguments`."
        )

        let keyed = try await loaded(String(lossyUTF8: withoutDestination) + "\ndestination: platform=macOS\n")
        XCTAssertEqual(keyed.firstDestination, "platform=macOS")
        let flagged = try await loaded(
            String(lossyUTF8: withoutDestination),
            flags: XcodebuildChoice(destinations: ["platform=macOS"])
        )
        XCTAssertEqual(flagged.firstDestination, "platform=macOS")
    }

    // Mutants are tested on the first destination the flag gives, as on the first in arguments.
    func test_theMergedDestination_isWhereMutantsAreTested() async throws {
        let configuration = try await loaded(
            xcodebuild + "arguments: [-scheme, App, -destination, id=0, test]",
            flags: XcodebuildChoice(destinations: ["platform=iOS Simulator,id=1", "id=2"])
        )

        XCTAssertEqual(configuration.firstDestination, "platform=iOS Simulator,id=1")
        XCTAssertEqual(
            Array(configuration.testWithoutBuildArguments(with: "muter.xctestrun").prefix(3)),
            ["test-without-building", "-destination", "platform=iOS Simulator,id=1"]
        )
    }

    // The header records the effective arguments alone, so a key and the same option in arguments resume each other.
    func test_theResultsHeader_recordsOnlyTheArguments() async throws {
        let keyed = try await loaded(xcodebuild + "arguments: [test]\nscheme: App\ndestination: platform=macOS\n")
        let written = try await loaded(xcodebuild + "arguments: [-scheme, App, -destination, platform=macOS, test]\n")

        XCTAssertEqual(keyed, written)
        let header = try String(lossyUTF8: JSONEncoder().encode(keyed))
        XCTAssertFalse(header.contains("\"scheme\""), header)
        XCTAssertFalse(header.contains("\"destination\""), header)
    }

    /// The configuration the run loads from `yaml`, with `flags`.
    private func loaded(
        _ yaml: String,
        flags: XcodebuildChoice = XcodebuildChoice(),
        line: UInt = #line
    ) async throws -> MuterConfiguration {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(yaml.utf8)
        state.runOptions = .make(xcodebuild: flags)
        let result = try await sut.run(with: state)
        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)", line: line)
            throw MuterError.literal(reason: "no configuration")
        }
        return configuration
    }

    private func assertXcodebuildChoiceRefused(
        _ yaml: String,
        _ reason: String,
        flags: XcodebuildChoice = XcodebuildChoice(),
        line: UInt = #line
    ) async {
        do {
            _ = try await loaded(yaml, flags: flags, line: line)
            XCTFail("\(yaml) wasn't refused", line: line)
        } catch let MuterError.configurationParsingError(refusal) {
            XCTAssertEqual(refusal, reason, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}
