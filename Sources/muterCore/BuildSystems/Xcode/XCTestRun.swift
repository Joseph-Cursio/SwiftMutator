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

    /// Its UI test targets (`IsUITestBundle`), each once, by the name `-only-testing` and `-skip-testing` take: its
    /// `BlueprintName`, else its `ProductModuleName`. A mutant's xcodebuild run that tests one doesn't stop at its
    /// first failed test (`MuterConfiguration.uiTestTargets`).
    var uiTestTargets: [String] {
        names(of: testTargets.filter { $0["IsUITestBundle"] as? Bool == true })
    }

    /// Every test target, each once, named as `uiTestTargets` names them.
    var testTargetNames: [String] {
        names(of: testTargets)
    }

    /// Its test targets that don't run in Xcode's `xctest` agent, each once, named as `uiTestTargets` names them: those
    /// hosted by an app (`IsAppHostedTestBundle`), UI test targets (`IsUITestBundle`), and any whose `TestHostPath`
    /// isn't the agent, `__PLATFORMS__/<platform>.platform/Developer/Library/Xcode/Agents/xctest`, or that has none.
    /// A Mac run whose tests are none of these can test several mutants at once
    /// (`MuterConfiguration.testsRunUnhosted`).
    var hostedTestTargets: [String] {
        names(of: testTargets.filter { target in
            target["IsUITestBundle"] as? Bool == true
                || target["IsAppHostedTestBundle"] as? Bool == true
                || (target["TestHostPath"] as? String)?.hasSuffix("/Library/Xcode/Agents/xctest") != true
        })
    }

    /// The names of `targets`, each once, in their order: each one's `BlueprintName`, else its `ProductModuleName`,
    /// the name `-only-testing` and `-skip-testing` take.
    private func names(of targets: [[String: AnyHashable]]) -> [String] {
        var names: [String] = []
        for target in targets {
            let name = (target["BlueprintName"] ?? target["ProductModuleName"]) as? String ?? "a target with no name"
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Every test target's entry, as `updateEnvironmentVariable` finds them: in each of `TestConfigurations`'
    /// `TestTargets`, or in the legacy format, every dictionary at the top level but `__xctestrun_metadata__`.
    private var testTargets: [[String: AnyHashable]] {
        guard let testConfigurations = plist["TestConfigurations"] as? [AnyHashable] else {
            return plist.filter { $0.key != "__xctestrun_metadata__" }.values
                .compactMap { $0 as? [String: AnyHashable] }
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
        var variables = [isMuterRunningKey: isMuterRunningValue]
        if let key {
            variables[key] = isMuterRunningValue
        }
        if let activationMarker {
            variables[activationMarkerKey] = activationMarker
        }
        return setting(variables)
    }

    /// This `.xctestrun` with `variables` set in every test target's `EnvironmentVariables`, over any of the same name:
    /// what an xcodebuild worker's runs add to their tests' environment (`MuterConfiguration.XcodeWorker.environment`).
    func adding(environment variables: [String: String]) -> Self {
        variables.isEmpty ? self : Self(setting(variables))
    }

    /// The plist with `variables` set in every test target's `EnvironmentVariables`.
    private func setting(_ variables: [String: String]) -> [String: AnyHashable] {
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
                            return updateEnvironmentVariables(forConfiguration: newTestTarget, setting: variables)
                                as AnyHashable
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
                        setting: variables
                    )
                }
            }
        }

        return copy
    }

    private func updateEnvironmentVariables(
        forConfiguration configuration: [String: AnyHashable],
        setting variables: [String: String]
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
        for (name, value) in variables {
            allEnvironmentVariables[name] = value
        }

        configuration[environmentVariablesKey] = allEnvironmentVariables

        return configuration
    }
}
