extension MuterConfiguration {
    /// Whether an xcodebuild run's workers test on this Mac, each from the mutated project's one build with an
    /// `.xctestrun` and derived data of its own, and none on a simulator: when the test command's first `-destination`
    /// is the Mac, `platform=macOS` with or without an `arch=`, and the tests run in Xcode's `xctest` agent, none of
    /// them hosted by an app or a UI test target (`testsRunUnhosted`). Such tests share the agent's `UserDefaults`
    /// domain and the user's home folder, as a SwiftPM run's do, which the run says. Killing xcodebuild's process tree
    /// was measured to end such a run's tests (`ProcessTree`). A Mac app's tests, UI tests and Mac Catalyst, which
    /// nothing measured, still test one mutant at a time (`parallelWorkersUnsupportedReason`).
    var testsOnMacWorkers: Bool {
        guard buildSystem == .xcodebuild, testsRunUnhosted, let destination = firstDestination else { return false }
        return Self.namesAMac(destination) && !Self.namesMacCatalyst(destination)
    }

    /// Whether `destination`, a `-destination` value, names Mac Catalyst: a Mac with a `variant=`.
    static func namesMacCatalyst(_ destination: String) -> Bool {
        namesAMac(destination) && destination.split(separator: ",").contains { pair in
            pair.split(separator: "=", maxSplits: 1).first.map { String($0).trimmed.lowercased() } == "variant"
        }
    }

    /// This configuration with whether the test targets a mutant's run tests, of those in `xctestrun`, the project's
    /// `.xctestrun`, all run in Xcode's `xctest` agent (`testsRunUnhosted`): all but those the test arguments' own
    /// `-skip-testing` leaves out, or their `-only-testing` doesn't name (`targetsTested(among:)`), so a hosted target
    /// they skip doesn't count. An `.xctestrun` with no test target the run tests shows nothing, and keeps it false.
    func withMacWorkerFact(given xctestrun: XCTestRun) -> Self {
        var copy = self
        copy.testsRunUnhosted = !targetsTested(among: xctestrun.testTargetNames).isEmpty
            && targetsTested(among: xctestrun.hostedTestTargets).isEmpty
        return copy
    }
}
