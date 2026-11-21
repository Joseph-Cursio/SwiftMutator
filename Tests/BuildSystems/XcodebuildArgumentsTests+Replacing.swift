@testable import muterCore
import XCTest

extension XcodebuildArgumentsTests {
    // An option's value is never taken for an option, so `-scheme test` keeps `test`, and `-only-testing -scheme`
    // has no `-scheme` option.
    func test_options_areFoundByName_withTheirValues() {
        let arguments = XcodebuildArguments([
            "-only-testing", "-scheme", "-scheme", "test", "-destination", "id=1", "test", "-destination", "id=2",
        ])

        XCTAssertEqual(arguments.options(named: ["-scheme"]).map(\.value), ["test"])
        XCTAssertEqual(arguments.options(named: ["-destination"]).map(\.value), ["id=1", "id=2"])
        XCTAssertEqual(arguments.options(named: ["-workspace", "-project"]), [])
        XCTAssertNil(XcodebuildArguments(["-scheme"]).options(named: ["-scheme"]).first?.value)
    }

    // Every occurrence goes, each with its value, and the replacement takes the first's place.
    func test_replacing_writesTheReplacementWhereTheFirstWas_andLeavesOutTheRest() {
        let arguments = XcodebuildArguments([
            "-scheme", "test", "-destination", "id=1", "-quiet", "-destination", "id=2", "test",
        ])

        XCTAssertEqual(
            arguments.replacing(["-destination"], with: ["-destination", "id=3"], placing: .beforeTheFirstAction),
            ["-scheme", "test", "-destination", "id=3", "-quiet", "test"]
        )
        XCTAssertEqual(
            arguments.replacing(["-scheme"], with: ["-scheme", "App"], placing: .after([])),
            ["-scheme", "App", "-destination", "id=1", "-quiet", "-destination", "id=2", "test"]
        )
    }

    // An option the arguments lack goes after the option named, or at the front; or before the first action, or at
    // the end.
    func test_replacing_placesAnOptionTheArgumentsLack() {
        let arguments = XcodebuildArguments(["-quiet", "-project", "App.xcodeproj", "clean", "test"])

        XCTAssertEqual(
            arguments.replacing(["-scheme"], with: ["-scheme", "App"], placing: .after(["-workspace", "-project"])),
            ["-quiet", "-project", "App.xcodeproj", "-scheme", "App", "clean", "test"]
        )
        XCTAssertEqual(
            arguments.replacing(["-workspace"], with: ["-workspace", "A.xcworkspace"], placing: .after(["-scheme"])),
            ["-workspace", "A.xcworkspace", "-quiet", "-project", "App.xcodeproj", "clean", "test"]
        )
        XCTAssertEqual(
            arguments.replacing(["-destination"], with: ["-destination", "id=1"], placing: .beforeTheFirstAction),
            ["-quiet", "-project", "App.xcodeproj", "-destination", "id=1", "clean", "test"]
        )
        XCTAssertEqual(
            XcodebuildArguments(["-scheme", "test"])
                .replacing(["-destination"], with: ["-destination", "id=1"], placing: .beforeTheFirstAction),
            ["-scheme", "test", "-destination", "id=1"]
        )
    }
}
