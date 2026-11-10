extension SwiftPackageBuildConditions {
    /// The custom conditions and language modes of a run's targets, and of the files each target compiles.
    struct TargetConditions {
        var targets: [Set<String>] = []
        var ofFile: [FilePath: [Set<String>]] = [:]
        var undecided: Set<String> = []
        var modes: [LanguageMode?] = []

        /// Adds those of `package`, whose manifest is `manifest`. False if a target of the package isn't in it.
        mutating func add(
            _ package: SwiftPackageSources.Package,
            manifest: PackageManifest,
            build: Build,
            buildsToolsWithFlags: Bool
        ) -> Bool {
            undecided.formUnion((manifest.traits ?? []).map(\.name))
            // SwiftPM builds a plugin in its tools version's mode, with `-Xbuild-tools-swiftc`'s flags.
            func languageMode(of target: PackageManifest.Target) -> LanguageMode? {
                guard target.type == "plugin" else {
                    return build.languageMode(of: target.settings ?? [], default: manifest.defaultLanguageMode)
                }
                return buildsToolsWithFlags ? nil : manifest.toolsVersionsLanguageMode
            }
            // A test target's or a plugin's are no target's here, but `--files-to-mutate` can name their files.
            for other in manifest.targets where !package.targets.contains(where: { $0.name == other.name }) {
                let conditions = build.conditions(of: other.settings ?? [])
                undecided.formUnion(conditions.set.subtracting(build.conditions(of: []).set))
                undecided.formUnion(conditions.undecided)
                modes.append(languageMode(of: other))
            }
            for target in package.targets {
                // Taking a target with no settings to read for one with none would decide its conditions wrongly.
                guard let declared = manifest.targets.first(where: { $0.name == target.name }) else {
                    return false
                }
                let conditions = build.conditions(of: declared.settings ?? [])
                targets.append(conditions.set)
                undecided.formUnion(conditions.undecided)
                modes.append(languageMode(of: declared))
                for file in target.files {
                    ofFile[file, default: []].append(conditions.set)
                }
            }
            return true
        }
    }

    /// Whether a manifest's setting applies in a build, or whether that can't be told.
    enum Applicability {
        case applies
        case doesNotApply
        case undecided
    }

    /// What decides a package's conditions in this build. `platform` is as a manifest's conditions name it; nil if
    /// SwiftMutator can't tell.
    struct Build {
        let configuration: String
        let platform: String?
        let flags: Set<String>

        /// The conditions a target with `settings` sets, and those that depend on what can't be told here.
        func conditions(of settings: [PackageManifest.Setting]) -> (set: Set<String>, undecided: Set<String>) {
            var set = flags.union(["SWIFT_PACKAGE"])
            if configuration == "debug" {
                set.insert("DEBUG")
            }
            var undecided: Set<String> = []
            for setting in settings where setting.tool == "swift" {
                let names = setting.kind.define.map { [$0._0] } ?? []
                let settingFlags = customConditions(inSwiftFlags: setting.kind.unsafeFlags?._0 ?? [])
                let declared = Set(names).union(settingFlags)
                switch applicability(of: setting.condition) {
                case .applies: set.formUnion(declared)
                case .doesNotApply: break
                case .undecided: undecided.formUnion(declared)
                }
            }
            return (set, undecided)
        }

        /// The language mode a target with `settings` builds in, in a package whose own is `packageMode`: the one its
        /// `swiftLanguageMode` sets, if it does. Nil if it can't be told: a setting that may or may not apply, one
        /// SwiftMutator can't read, two that differ, or flags that set it.
        func languageMode(of settings: [PackageManifest.Setting], default packageMode: LanguageMode?) -> LanguageMode? {
            var targetsOwn: LanguageMode?
            for setting in settings where setting.tool == "swift" {
                let setsIt = setting.kind.setsLanguageMode
                    || LanguageMode.isSet(inFlags: setting.kind.unsafeFlags?._0 ?? [])
                guard setsIt else { continue }
                switch applicability(of: setting.condition) {
                case .doesNotApply:
                    continue

                case .applies:
                    guard let mode = setting.kind.languageMode, targetsOwn == nil || targetsOwn == mode else {
                        return nil
                    }
                    targetsOwn = mode

                case .undecided:
                    return nil
                }
            }
            return targetsOwn ?? packageMode
        }

        /// Whether a setting with `condition` applies; undecided if it can't be told, as for one that a trait enables.
        private func applicability(of condition: PackageManifest.Condition?) -> Applicability {
            guard let condition else { return .applies }
            if let config = condition.config, config != configuration {
                return .doesNotApply
            }
            guard (condition.traits ?? []).isEmpty else { return .undecided }
            let platforms = condition.platformNames ?? []
            guard !platforms.isEmpty else { return .applies }
            guard let platform else { return .undecided }
            return platforms.contains(platform) ? .applies : .doesNotApply
        }
    }
}
