@testable import muterCore
import XCTest

/// The gate keys, `baseline`, `maxNewSurvivors`, `maxScoreDrop` and `maxDoubtfulKills`, as their flags take them.
extension ConfigurationParsingTests {
    private static let swiftTest = "executable: /usr/bin/swift\narguments: [test]"

    private func gates(_ lines: String...) throws -> RunGates {
        try MuterConfiguration(from: Data(([Self.swiftTest] + lines).joined(separator: "\n").utf8)).gates
    }

    // Each as written: a path, as it is, whole counts from 0, and points as `--max-score-drop` takes them.
    func test_parseRunGates() throws {
        XCTAssertEqual(
            try gates(
                "baseline: ci/muter.baseline.yml",
                "maxNewSurvivors: 3",
                "maxScoreDrop: 2.5",
                "maxDoubtfulKills: 0"
            ),
            RunGates(baseline: "ci/muter.baseline.yml", maxNewSurvivors: 3, maxScoreDrop: 2.5, maxDoubtfulKills: 0)
        )
        XCTAssertEqual(try gates("maxNewSurvivors: 0", "maxScoreDrop: 0").maxScoreDrop, 0)
        XCTAssertEqual(try gates("maxScoreDrop: 100").maxScoreDrop, 100)
        XCTAssertEqual(try gates("maxScoreDrop: 0.000001").maxScoreDrop, 0.000001)
        XCTAssertEqual(try gates("baseline: \"~/b.yml\"").baseline, "~/b.yml")
        // Unset, as an older header has them, none is checked.
        XCTAssertEqual(try gates(), RunGates())
    }

    // Each is written only when set, as it was read, in YAML and in JSON, so an older header stays as it was, and a
    // header's reads back.
    func test_runGates_areWrittenOnlyWhenSet_andReadBack() throws {
        let plain = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let unsetYAML = String(lossyUTF8: try plain.asData)
        for key in ["baseline", "maxNewSurvivors", "maxScoreDrop", "maxDoubtfulKills"] {
            XCTAssertFalse(unsetYAML.contains(key), key)
            XCTAssertFalse(String(lossyUTF8: try JSONEncoder().encode(plain)).contains(key), key)
        }

        let set = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            gates: RunGates(baseline: "muter.baseline.yml", maxNewSurvivors: 1, maxScoreDrop: 0.5, maxDoubtfulKills: 2)
        )
        let yaml = try set.asData
        let yamlText = String(lossyUTF8: yaml)
        for line in ["baseline: muter.baseline.yml", "maxNewSurvivors: 1", "maxScoreDrop: 0.5", "maxDoubtfulKills: 2"] {
            XCTAssertTrue(yamlText.contains("\n\(line)\n"), yamlText)
        }
        XCTAssertEqual(try MuterConfiguration(from: yaml), set)
        let json = try JSONEncoder().encode(set)
        XCTAssertTrue(String(lossyUTF8: json).contains("\"maxScoreDrop\":0.5"), String(lossyUTF8: json))
        XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: json), set)
        // A whole number of points, as Yams would write 2.0 otherwise.
        let whole = MuterConfiguration(executable: "/usr/bin/swift", arguments: [], gates: RunGates(maxScoreDrop: 2))
        XCTAssertTrue(String(lossyUTF8: try whole.asData).contains("\nmaxScoreDrop: 2\n"))
    }

    // A blank key, a negative count, a value of another kind or points out of range are configuration errors, rather
    // than a gate not checked.
    func test_runGates_ofAnotherKind_blank_orOutOfRange_failToParse() {
        let refused = [
            ("baseline:", "baseline must be a baseline file's path. Leave it out to compare with none."),
            ("baseline: \"  \"", "baseline must be a baseline file's path."),
            ("baseline: [a.yml]", "baseline must be a baseline file's path."),
            ("maxNewSurvivors:", "maxNewSurvivors is blank. Give it a value, or leave it out to check none."),
            ("maxNewSurvivors: -1", "maxNewSurvivors must be a whole number at least 0, not -1"),
            ("maxNewSurvivors: 1.5", ""),
            ("maxNewSurvivors: many", ""),
            ("maxScoreDrop:", "maxScoreDrop is blank."),
            ("maxScoreDrop: -1", "maxScoreDrop must be a number from 0 to 100, with at most 6 decimals, such as 2 or "
                + "0.5, not -1"),
            ("maxScoreDrop: 100.5", "not 100.5"),
            ("maxScoreDrop: 1e2", "not 1e2"),
            ("maxScoreDrop: [2]", ""),
            ("maxDoubtfulKills:", "maxDoubtfulKills is blank."),
            ("maxDoubtfulKills: -2", "maxDoubtfulKills must be a whole number at least 0, not -2"),
            ("maxDoubtfulKills: none", ""),
        ]
        for (line, reason) in refused {
            XCTAssertThrowsError(try gates(line), line) { error in
                XCTAssertTrue(reason.isEmpty || "\(error)".contains(reason), "\(line): \(error)")
            }
        }
        // A results header's JSON is checked as the YAML is.
        let json = Data(#"{"executable": "/usr/bin/swift", "arguments": [], "maxNewSurvivors": -1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MuterConfiguration.self, from: json))
        let blank = Data(#"{"executable": "/usr/bin/swift", "arguments": [], "baseline": null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MuterConfiguration.self, from: blank))
    }

    // A count with no baseline file decodes: `--baseline` may give the file, so `LoadConfiguration` refuses it once
    // the run's flags are in. `init`'s file, every example uncommented, has both anyway.
    func test_aCountWithoutABaseline_decodes() throws {
        XCTAssertEqual(try gates("maxNewSurvivors: 2", "maxScoreDrop: 1").maxNewSurvivors, 2)
    }
}
