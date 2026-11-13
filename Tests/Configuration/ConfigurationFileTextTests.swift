@testable import muterCore
import XCTest

final class ConfigurationFileTextTests: MuterTestCase {
    private let xcodeProject = MuterConfiguration(
        executable: "/usr/bin/xcodebuild",
        arguments: [
            "-project", "My App.xcodeproj", "-scheme", "My App",
            "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "test",
        ]
    )

    // A key the configuration doesn't hold is never added: each one has an entry, once.
    func test_everyKey_hasOneEntry() {
        let keys = ConfigurationFileText.entries.map(\.key.rawValue)

        XCTAssertEqual(keys.sorted(), MuterConfiguration.CodingKeys.allCases.map(\.rawValue).sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // The file reads back as the configuration it was written for: the arguments' spaces and commas survive YAML.
    func test_theFile_readsBackAsTheConfiguration() throws {
        for configuration in [xcodeProject, MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])] {
            let text = try ConfigurationFileText.text(for: configuration)

            XCTAssertEqual(try MuterConfiguration(from: Data(text.utf8)), configuration, text)
        }
    }

    // Each key is written once, at the start of a line: `executable` and `arguments` as they are, and every other,
    // left at its default, commented out, under a comment that says its default.
    func test_onlyExecutableAndArguments_areWritten_andEveryOtherKeyIsCommentedOut() throws {
        let lines = try ConfigurationFileText.text(for: xcodeProject).split(separator: "\n").map(String.init)

        for key in MuterConfiguration.CodingKeys.allCases.map(\.rawValue) {
            let written = lines.filter { $0.hasPrefix("\(key):") }
            let commentedOut = lines.filter { $0.hasPrefix("# \(key):") }
            if key == "executable" || key == "arguments" {
                XCTAssertEqual([written.count, commentedOut.count], [1, 0], key)
            } else {
                XCTAssertEqual([written.count, commentedOut.count], [0, 1], key)
            }
        }
        XCTAssertEqual(ConfigurationFileText.entries.filter { !$0.comment.contains("Default:") }.map(\.key), [
            .testCommandExecutable, .testCommandArguments,
        ])
        XCTAssertFalse(lines.contains { $0.count > ConfigurationFileText.width }, "\(lines)")
    }

    // Removing every `# ` from a key and its value gives a file SwiftMutator reads: each example is a value the key
    // takes, and each default is the default.
    func test_everyExample_isAValueItsKeyTakes() throws {
        let text = try ConfigurationFileText.text(for: xcodeProject)
        let keys = MuterConfiguration.CodingKeys.allCases.map(\.rawValue)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let isAKeyOrAValue = line.hasPrefix("# - ") || keys.contains { line.hasPrefix("# \($0):") }
            return isAKeyOrAValue ? String(line.dropFirst(2)) : String(line)
        }
        let uncommented = lines.joined(separator: "\n")

        let configuration = try MuterConfiguration(from: Data(uncommented.utf8))

        XCTAssertEqual(configuration.stopAtFirstFailure, .enabled)
        XCTAssertEqual(configuration.suspectTestFilePercent, SuspectTestThresholds.standard.filePercent)
        XCTAssertEqual(configuration.controlRunEvery, MuterConfiguration.defaultMutantsPerControlRun)
        XCTAssertEqual(configuration.operators, MutationOperator.Id.allCases)
        XCTAssertEqual(configuration.reports?.count, 1)
        XCTAssertEqual(configuration.coverageThreshold, 0)
    }

    // A key set to other than its default is written as it is, and `exclude` with its entries.
    func test_aKeyThatIsntAtItsDefault_isWritten() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            excludeList: ["Sources/Generated"],
            stopAtFirstFailure: .disabled
        )

        let text = try ConfigurationFileText.text(for: configuration)

        XCTAssertTrue(text.contains("\nexclude:\n- Sources/Generated\n"), text)
        XCTAssertTrue(text.contains("\nstopAtFirstFailure: false\n"), text)
        XCTAssertTrue(text.contains("\n# excludeCalls:\n"), text)
        XCTAssertEqual(try MuterConfiguration(from: Data(text.utf8)), configuration)
    }

    // YAML writes a line break in a quoted string as a blank line, which is part of the value.
    func test_aValueWithALineBreak_readsBackAsItWas() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test", "--filter", "a\nb"])

        let text = try ConfigurationFileText.text(for: configuration)

        XCTAssertEqual(try MuterConfiguration(from: Data(text.utf8)), configuration, text)
    }

    func test_wrapped_breaksBetweenWords() {
        XCTAssertEqual(ConfigurationFileText.wrapped("one two three four", width: 9), ["one two", "three", "four"])
        XCTAssertEqual(ConfigurationFileText.wrapped("", width: 9), [])
    }
}
