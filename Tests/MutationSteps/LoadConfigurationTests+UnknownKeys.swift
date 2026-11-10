@testable import muterCore
import XCTest

extension LoadConfigurationTests {
    // #122: a misspelled key was dropped without a word.
    func test_unknownKeys_areSent_withTheFilesName_andTheRunGoesOn() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nmutationTestTimeOut: 120\n".utf8
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(sent.events.count, 1)
        XCTAssertEqual(sent.events.first?.file, MuterConfiguration.fileNameWithExtension)
        XCTAssertEqual(sent.events.first?.keys, [.init(key: "mutationTestTimeOut", closest: "mutationTestTimeout")])
        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertNil(configuration.testSuiteTimeout)
    }

    // So a misspelled required key is named, besides the error that it's missing.
    func test_unknownKeys_areSent_evenWhenTheFileIsRefused() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data("executible: /usr/bin/swift\narguments: [test]\n".utf8)

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case let .configurationParsingError(reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("executable"), reason)
        }

        XCTAssertEqual(sent.events.first?.keys, [.init(key: "executible", closest: "executable")])
    }

    // Converting it would drop the key the warning names, and the next run would say nothing of it: it is kept, with
    // its name in the warning, until the key is fixed.
    func test_aLegacyFileWithAnUnknownKey_isNamed_andNotConverted() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [true, false]
        fileManager.fileContentsToReturn = Data(
            #"{"executable": "/usr/bin/swift", "arguments": ["test"], "mutationTestTimeOut": 120}"#.utf8
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent.events.first?.file, MuterConfiguration.legacyFileNameWithExtension)
        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"))
    }

    // So it isn't taken for the project's own `muter.conf.yml`.
    func test_aConfigurationFileElsewhere_isNamedByItsPath() async throws {
        let sent = recordedUnknownKeys()
        let file = Data("executable: /usr/bin/swift\narguments: [test]\ncolour: blue\n".utf8)

        for folder in ["\(fixturesDirectory)/ci", "/elsewhere/ci.yml"] {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = file
            state.runOptions = .make(configurationURL: URL(fileURLWithPath: folder))
            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(sent.events.map(\.file), ["ci/\(MuterConfiguration.fileNameWithExtension)", "/elsewhere/ci.yml"])
    }

    // What an earlier version wrote for any value but these, and then ignored, as it is now.
    func test_buildSystemUnknown_isTakenAsUnset() async throws {
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = Data(
            "executable: /usr/bin/swift\narguments: [test]\nbuildSystem: unknown\n".utf8
        )

        let result = try await sut.run(with: state)

        guard case let .configurationParsed(configuration)? = result.last else {
            XCTFail("\(result)")
            return
        }
        XCTAssertNil(configuration.explicitBuildSystem)
    }

    func test_noUnknownKey_sendsNothing() async throws {
        let sent = recordedUnknownKeys()
        fileManager.fileExistsToReturn = [false, true]
        fileManager.fileContentsToReturn = loadYAMLConfiguration()

        _ = try await sut.run(with: state)

        XCTAssertTrue(sent.events.isEmpty)
    }

    /// Each `configurationKeysUnknown` from now on.
    func recordedUnknownKeys() -> RecordedUnknownKeys {
        let recorded = RecordedUnknownKeys()
        let observer = runEvents.observe(.configurationKeysUnknown) { event in
            if let sent = event.object as? ([UnknownConfigurationKey], String) {
                recorded.events.append((keys: sent.0, file: sent.1))
            }
        }
        addTeardownBlock { observer.cancel() }
        return recorded
    }

    final class RecordedUnknownKeys {
        var events: [(keys: [UnknownConfigurationKey], file: String)] = []
    }
}
