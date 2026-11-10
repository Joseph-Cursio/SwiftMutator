@testable import muterCore
import XCTest

extension ConfigurationParsingTests {
    // Not a configuration key: neither the configuration file nor a results file's header holds it.
    func test_xcodeWorker_isNeverEncoded() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let withWorker = configuration.forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        ))

        XCTAssertEqual(try withWorker.asData, try configuration.asData)
        XCTAssertEqual(try MuterConfiguration(from: withWorker.asData), configuration)
    }

    func test_asData_writesStopAtFirstFailureOnlyWhenSet() throws {
        // Left out while unset, so `init` and the JSON-to-YAML migration write the same files as before.
        let unset = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertFalse(try String(lossyUTF8: unset.asData).contains("stopAtFirstFailure"))

        for (value, written) in [(ConfigurationSwitch.enabled, "true"), (.disabled, "false")] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: ["test"],
                stopAtFirstFailure: value
            )

            XCTAssertTrue(
                try String(lossyUTF8: configuration.asData).contains("stopAtFirstFailure: \(written)")
            )
            XCTAssertEqual(try MuterConfiguration(from: configuration.asData), configuration)
        }
    }

    func test_configurationWithEveryFieldSet_leavesNoFieldAtItsDefault() {
        // A field added to MuterConfiguration fails this until the helper in Fixtures.swift sets it, which makes
        // the copy tests that follow cover the new field too.
        let fields = Mirror(reflecting: configurationWithEveryFieldSet()).children
        let defaults = Mirror(reflecting: MuterConfiguration()).children
        for (field, defaultField) in zip(fields, defaults) {
            XCTAssertNotEqual(
                "\(field.value)",
                "\(defaultField.value)",
                "\(field.label ?? "a field") is at its default"
            )
        }
    }

    func test_operatorKeys_areRead_andAnythingElseIsAConfigurationError() throws {
        let start = "executable: /usr/bin/swift\narguments: [test]\n"
        let read = { (line: String) in try MuterConfiguration(from: Data((start + line).utf8)) }

        let set = try read("operators: [SwapTernary, RelationalBoundary]\nskipOperators: [SwapTernary]")
        XCTAssertEqual(set.operators, [.swapTernary, .relationalBoundary])
        XCTAssertEqual(set.skipOperators, [.swapTernary])
        XCTAssertEqual(try read("skipOperators: []").skipOperators, [])
        let neither = try read("")
        XCTAssertNil(neither.operators)
        XCTAssertNil(neither.skipOperators)

        let wrong = [
            ("operators: [SwapTernery]", "SwapTernery isn't an operator"),
            ("skipOperators: [SwapTernery]", "SwapTernery isn't an operator"),
            ("operators: []", "must name at least one operator"),
            ("operators:", "must name at least one operator"),
            ("operators: SwapTernary", ""),
            ("skipOperators: 3", ""),
        ]
        for (line, reason) in wrong {
            XCTAssertThrowsError(try read(line), line) { error in
                XCTAssertTrue(reason.isEmpty || "\(error)".contains(reason), "\(error)")
            }
        }
    }

    func test_everyKey_isWritten_andReadBack() throws {
        // encode(to:) is written by hand, so a key added to CodingKeys but not written there would be lost from every
        // results header and never compared on a resume.
        let configuration = configurationWithEveryFieldSet()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(configuration)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertEqual(Set(written.keys), Set(MuterConfiguration.CodingKeys.allCases.map(\.stringValue)))
        XCTAssertEqual(
            try encoder.encode(JSONDecoder().decode(MuterConfiguration.self, from: json)),
            json
        )
        XCTAssertEqual(
            try encoder.encode(MuterConfiguration(from: configuration.asData)),
            json
        )
    }

    func test_withExecutable_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet().withExecutable("/opt/homebrew/bin/swift"),
            configurationWithEveryFieldSet(executable: "/opt/homebrew/bin/swift")
        )
    }

    func test_withDefaultTestSuiteTimeout_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(timeout: nil).withDefaultTestSuiteTimeout(12),
            configurationWithEveryFieldSet(timeout: 12)
        )
    }

    func test_forXcodeWorker_keepsEveryOtherField() throws {
        let configuration = configurationWithEveryFieldSet()
        let worker = try XCTUnwrap(configuration.xcodeWorker)
        let other = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )

        XCTAssertEqual(configuration.forXcodeWorker(other).xcodeWorker, other)
        XCTAssertEqual(configuration.forXcodeWorker(other).forXcodeWorker(worker), configuration)
    }

    func test_withUnreliableFailedTestLines_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(failedTestLinesAreReliable: true)
                .withUnreliableFailedTestLines(printedIn: [failedTestLookalikeLog]),
            configurationWithEveryFieldSet(failedTestLinesAreReliable: false)
        )
    }
}
