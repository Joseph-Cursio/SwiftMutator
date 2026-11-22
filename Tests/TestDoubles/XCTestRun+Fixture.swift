@testable import muterCore

extension XCTestRun {
    /// Xcode's `xctest` agent, as a Mac test target that no app hosts names it for its `TestHostPath`.
    static let macAgentPath = "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"

    /// A Mac app's path, as a test target the app hosts names it for its `TestHostPath`.
    static let macAppPath = "__TESTROOT__/Debug/App.app"

    /// One test target, `SumTests`, that runs in Xcode's `xctest` agent on a Mac, as a Swift package's does.
    static let unhostedFixture = withTestTargets(["SumTests": ["TestHostPath": macAgentPath]])

    /// An `.xctestrun` in the test plan format with `targets`, each by its `BlueprintName`, with its other keys.
    static func withTestTargets(_ targets: KeyValuePairs<String, [String: AnyHashable]>) -> XCTestRun {
        let entries = targets.map { name, keys in
            keys.merging(["BlueprintName": name]) { own, _ in own } as AnyHashable
        }
        return XCTestRun([
            "TestConfigurations": [["TestTargets": entries] as [String: AnyHashable]],
        ])
    }
}
