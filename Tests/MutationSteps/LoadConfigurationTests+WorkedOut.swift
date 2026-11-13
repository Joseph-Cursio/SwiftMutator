@testable import muterCore
import XCTest

extension LoadConfigurationTests {
    // #263: with no configuration file, a run tests with what `init` would write, says so, and marks it worked out.
    func test_withoutAConfigurationFile_theRunWorksItOut_andSaysSo() async throws {
        let sent = recordedWorkedOut()
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["Package.swift", "Sources"]
        process.stdoutToBeReturned = "/usr/bin/swift"

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(configuration.testCommandExecutable, "/usr/bin/swift")
        XCTAssertEqual(configuration.testCommandArguments, ["test"])
        XCTAssertTrue(configuration.workedOut)
        XCTAssertEqual(sent.events.map(\.missing), [MuterConfiguration.fileNameWithExtension])
        XCTAssertEqual(sent.events.first?.generated.configuration.testCommandArguments, ["test"])
        // A package's configuration needs only the folder's top: nothing below it is listed.
        XCTAssertFalse(fileManager.methodCalls.contains("subpaths(atPath:)"))
    }

    // A file that is there isn't worked out.
    func test_aConfigurationFile_isntMarkedWorkedOut() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("executable: /usr/bin/swift\narguments: [test]\n".utf8)

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertFalse(configuration.workedOut)
    }

    // Nothing to work a test command out from refuses the run, as a missing file did, and says why: from the folder's
    // top alone, so that a run from the wrong folder, as a home folder, doesn't list everything below it first.
    func test_withNothingToWorkOutATestCommandFrom_theRunIsRefused() async throws {
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["main.swift", "Example"]
        fileManager.subpathsToReturn = ["main.swift", "Example", "Example/Demo.xcodeproj"]

        await assertRefused(
            "Could not find muter.conf at path \(fixturesDirectory)/muter.conf.yml, and the project's folder has no "
                + "Package.swift, Xcode workspace or Xcode project at its top to work out a test command from."
        )
        XCTAssertFalse(fileManager.methodCalls.contains("subpaths(atPath:)"))
    }

    // A Package.swift with no `swift` on PATH names what is missing, not the Package.swift that is there.
    func test_withAPackageAndNoSwiftOnThePath_theRunIsRefused_sayingSo() async throws {
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["Package.swift"]

        await assertRefused(
            "Could not find muter.conf at path \(fixturesDirectory)/muter.conf.yml, and SwiftMutator could not find "
                + "\"swift\" on your PATH to run the project's tests with."
        )
    }

    // An Xcode project at the top whose project.pbxproj can't be read, and no Package.swift, says so.
    func test_withAnUnreadableXcodeProject_theRunIsRefused_sayingSo() async throws {
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["Gone.xcodeproj"]
        fileManager.subpathsToReturn = ["Gone.xcodeproj"]

        await assertRefused(
            "Could not find muter.conf at path \(fixturesDirectory)/muter.conf.yml, and SwiftMutator can't read the "
                + "project.pbxproj of the Xcode project at the top of the project's folder to work out a test command "
                + "from."
        )
    }

    // Two workspaces can't be chosen between.
    func test_withTwoWorkspaces_theRunIsRefused() async throws {
        fileManager.fileExistsToReturn = [false, false]
        fileManager.contentsOfDirectoryToReturn = ["A.xcworkspace", "B.xcworkspace"]
        fileManager.subpathsToReturn = ["A.xcworkspace", "B.xcworkspace"]

        await assertRefused(
            "Could not find muter.conf at path \(fixturesDirectory)/muter.conf.yml. There is more than one Xcode "
                + "workspace in the project's folder (A.xcworkspace, B.xcworkspace), so SwiftMutator can't tell which "
                + "one runs your tests. Write muter.conf.yml yourself: see Configuration in SwiftMutator's README."
        )
    }

    // A file `--configuration` names, or one in the folder it names, is the file the run means: it isn't worked out.
    func test_whenTheConfigurationFlagNamesAFileThatIsntThere_theRunIsRefused() async throws {
        for path in ["/some/where/ci.yml", "/some/where"] {
            fileManager.fileExistsToReturn = [false, false]
            fileManager.contentsOfDirectoryToReturn = ["Package.swift"]
            state.runOptions = .make(configurationURL: URL(fileURLWithPath: path))
            let file = path.hasSuffix(".yml") ? path : "\(path)/muter.conf.yml"

            await assertRefused("Could not find muter.conf at path \(file)")
        }
        XCTAssertEqual(process.processesRun, [])
    }

    private func assertRefused(_ reason: String, line: UInt = #line) async {
        do {
            _ = try await sut.run(with: state)
            XCTFail("The run wasn't refused", line: line)
        } catch let MuterError.configurationParsingError(refusal) {
            XCTAssertEqual(refusal, reason, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }

    /// Each `configurationWorkedOut` from now on.
    func recordedWorkedOut() -> RecordedWorkedOut {
        let recorded = RecordedWorkedOut()
        let observer = runEvents.observe(.configurationWorkedOut) { event in
            if let sent = event.object as? (GeneratedConfiguration, String) {
                recorded.events.append((generated: sent.0, missing: sent.1))
            }
        }
        addTeardownBlock { observer.cancel() }
        return recorded
    }

    final class RecordedWorkedOut {
        var events: [(generated: GeneratedConfiguration, missing: String)] = []
    }
}
