struct XCTestRun: Equatable, @unchecked Sendable { // `plist` is a `let` of property-list values, none of them mutable
    /// The .xctestrun as `PropertyListSerialization` reads it: strings, numbers, dates, data, and arrays and
    /// dictionaries of them, held as `AnyHashable`, which the compiler can't see are values.
    private let plist: [String: AnyHashable]

    init(_ plist: [String: AnyHashable] = [:]) {
        self.plist = plist
    }

    /// Whether xcodebuild's parallel testing is on for any of its test targets (`ParallelizationEnabled`), as the
    /// scheme or the test plan sets it. A run from it, as a mutant's is, then clones the destination's simulator, and
    /// boots the clone, for its tests, unless the test command's `-parallel-testing-enabled` says otherwise: about
    /// 15 s a run, which a simulator of its own doesn't cost (`SimulatorWorkerSetup.oneWorkerPlan(for:state:)`).
    var parallelizes: Bool {
        testTargets.contains { $0["ParallelizationEnabled"] as? Bool == true }
    }

    /// Every test target's entry, as `updateEnvironmentVariable` finds them: in each of `TestConfigurations`'
    /// `TestTargets`, or in the legacy format, every dictionary at the top level.
    private var testTargets: [[String: AnyHashable]] {
        guard let testConfigurations = plist["TestConfigurations"] as? [AnyHashable] else {
            return plist.values.compactMap { $0 as? [String: AnyHashable] }
        }
        return testConfigurations.flatMap { testConfiguration in
            let configuration = testConfiguration as? [String: AnyHashable]
            let configuredTargets = configuration?["TestTargets"] as? [AnyHashable] ?? []
            return configuredTargets.compactMap { $0 as? [String: AnyHashable] }
        }
    }

    /// The plist with `key`, a mutant's switch, `activationMarker`, its marker's path, and `IS_MUTER_RUNNING` set in
    /// every test target's `EnvironmentVariables`. With no `key`, only `IS_MUTER_RUNNING`: a run with no mutant on, as
    /// SwiftMutator's runs of the tests are.
    func updateEnvironmentVariable(
        setting key: String?,
        activationMarker: String? = nil
    ) -> [String: AnyHashable] {
        var copy = plist
        let testConfigurationsKey = "TestConfigurations"
        let testTargetsKey = "TestTargets"

        if let testConfigurations = copy[testConfigurationsKey] as? [AnyHashable] {
            // TestPlan configuration
            let newTestConfigurations = testConfigurations.map { testConfiguration in
                if var newTestConfiguration = testConfiguration as? [String: AnyHashable],
                   let replacementTargets = newTestConfiguration[testTargetsKey] as? [AnyHashable] {
                    let newTestTargets = replacementTargets.map { testTarget in
                        if let newTestTarget = testTarget as? [String: AnyHashable] {
                            return updateEnvironmentVariables(
                                forConfiguration: newTestTarget,
                                key: key,
                                activationMarker: activationMarker
                            ) as AnyHashable
                        }
                        return testTarget
                    }

                    newTestConfiguration[testTargetsKey] = newTestTargets

                    return newTestConfiguration as AnyHashable
                }
                return testConfiguration
            }

            copy[testConfigurationsKey] = newTestConfigurations
        } else {
            // Legacy Tests configuration
            for (plistEntry, plistValue) in copy {
                if let testConfiguration = plistValue as? [String: AnyHashable] {
                    copy[plistEntry] = updateEnvironmentVariables(
                        forConfiguration: testConfiguration,
                        key: key,
                        activationMarker: activationMarker
                    )
                }
            }
        }

        return copy
    }

    private func updateEnvironmentVariables(
        forConfiguration configuration: [String: AnyHashable],
        key: String?,
        activationMarker: String?
    ) -> [String: AnyHashable] {
        let environmentVariablesKey = "EnvironmentVariables"
        var configuration = configuration

        // Create the `EnvironmentVariables` dict when absent instead of skipping. A freshly generated
        // .xctestrun has no such dict for a target, so the old `keys.contains` guard silently never
        // wrote the schemata activation var. On the `test-without-building -xctestrun` path (used for
        // simulator-hosted targets, where the env must ride in via the xctestrun rather than the parent
        // process) the mutant then never activated in the test host — every mutant became a false
        // "survived", i.e. a phantom 0% score.
        var allEnvironmentVariables = configuration[environmentVariablesKey] as? [String: AnyHashable] ?? [:]
        if let key {
            allEnvironmentVariables[key] = isMuterRunningValue
        }
        if let activationMarker {
            allEnvironmentVariables[activationMarkerKey] = activationMarker
        }
        allEnvironmentVariables[isMuterRunningKey] = isMuterRunningValue

        configuration[environmentVariablesKey] = allEnvironmentVariables

        return configuration
    }
}
