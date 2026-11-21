@testable import muterCore
import XCTest

extension ConfigurationParsingTests {
    // `destination` is one string or a list, kept as a list; each key is optional, so an older header still reads.
    func test_xcodebuildKeys_areRead_destinationAsAStringOrAList() throws {
        let start = "executable: /usr/bin/xcodebuild\narguments: [test]\n"
        let read = { (yaml: String) in try MuterConfiguration(from: Data((start + yaml).utf8)).xcodebuild }

        XCTAssertEqual(
            try read("workspace: App.xcworkspace\nscheme: App\ndestination: platform=iOS Simulator,name=iPhone 17\n"),
            XcodebuildChoice(
                workspace: "App.xcworkspace",
                scheme: "App",
                destinations: ["platform=iOS Simulator,name=iPhone 17"]
            )
        )
        XCTAssertEqual(
            try read("project: App.xcodeproj\ndestination:\n- platform=macOS\n- id=1234\n"),
            XcodebuildChoice(project: "App.xcodeproj", destinations: ["platform=macOS", "id=1234"])
        )
        // Not refused here, but once the run's flags are in: a results header must still read.
        XCTAssertEqual(
            try read("workspace: App.xcworkspace\nproject: App.xcodeproj\n"),
            XcodebuildChoice(workspace: "App.xcworkspace", project: "App.xcodeproj")
        )
        XCTAssertEqual(try read(""), XcodebuildChoice())
    }

    // A blank value would give xcodebuild nothing to open, build or test on, so it is refused, not taken as unset.
    func test_aBlankXcodebuildKey_orOneOfAnotherType_isRefused() {
        let start = "executable: /usr/bin/xcodebuild\narguments: [test]\n"
        let refused = [
            ("scheme:", "scheme must be a scheme's name"),
            ("scheme: ''", "scheme must be a scheme's name"),
            ("scheme: [App]", "scheme must be a scheme's name"),
            ("workspace:", "workspace must be a workspace's path"),
            ("project: ' '", "project must be a project's path"),
            ("destination:", "destination must be a destination"),
            ("destination: []", "destination must be a destination"),
            ("destination: [platform=macOS, '']", "destination must be a destination"),
            ("destination: {platform: macOS}", "destination must be a destination"),
        ]
        for (yaml, reason) in refused {
            XCTAssertThrowsError(try MuterConfiguration(from: Data((start + yaml).utf8)), yaml) { error in
                XCTAssertTrue("\(error)".contains(reason), "\(yaml): \(error)")
            }
        }
    }

    // Written only when set, `destination` as a list, and read back as it was, from YAML and from JSON.
    func test_xcodebuildKeys_areWrittenOnlyWhenSet_andReadBack() throws {
        let unset = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let text = try String(lossyUTF8: unset.asData)
        for key in ["workspace", "project", "scheme", "destination"] {
            XCTAssertFalse(text.contains("\(key):"), text)
        }

        let set = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["test"],
            xcodebuild: XcodebuildChoice(project: "App.xcodeproj", scheme: "App", destinations: ["platform=macOS"])
        )
        XCTAssertTrue(try String(lossyUTF8: set.asData).contains("destination:\n- platform=macOS\n"))
        XCTAssertEqual(try MuterConfiguration(from: set.asData), set)
        XCTAssertEqual(try JSONDecoder().decode(MuterConfiguration.self, from: JSONEncoder().encode(set)), set)
    }
}
