import Foundation

extension XcodeTestReach {
    /// The settings that say which app or bundle hosts or loads a test target's tests, or which target a UI test
    /// target drives, and the linker flags, which can link another target's product.
    static let followedSettings: Set = ["TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME", "OTHER_LDFLAGS"]

    /// The linker flags that name a framework in the next argument.
    static let frameworkFlags: Set = [
        "-framework", "-weak_framework", "-reexport_framework", "-lazy_framework", "-upward_framework",
        "-merge_framework",
    ]
    /// The linker flags that name a library joined to them, as `-lz` does.
    static let libraryFlags = ["-weak-l", "-reexport-l", "-lazy-l", "-upward-l", "-l"]

    /// The targets `target`, of the project at `project`, depends on explicitly, in it or in another project read;
    /// nil if one can't be followed. A dependency on a package's product leads to no target.
    static func explicitDependencies(
        of target: [String: Any],
        in project: FilePath,
        projects: Projects
    ) -> [XcodeTargetKey]? {
        guard let file = projects[project] else { return nil }
        var dependencies: [XcodeTargetKey] = []
        for dependency in (target["dependencies"] as? [String] ?? []).compactMap({ file.objects[$0] }) {
            if let id = dependency["target"] as? String {
                dependencies.append(XcodeTargetKey(project: project, id: id))
            } else if let proxy = dependency["targetProxy"] as? String {
                guard let remote = remoteObject(of: proxy, in: project, projects: projects) else { return nil }
                dependencies.append(remote)
            } else if dependency["productRef"] == nil {
                return nil
            }
        }
        return dependencies
    }

    /// The targets a test target's settings name as the app or bundle that hosts or loads its tests, or the target a
    /// UI test target drives, as its project file or the build configuration files it's based on set them; nil if one
    /// names something SwiftMutator can't place, or a file it can't read.
    static func hostTargets(
        of target: [String: Any],
        in project: FilePath,
        file: ProjectFile,
        index: XcodeTargetIndex
    ) -> [XcodeTargetKey]? {
        let list = (target["buildConfigurationList"] as? String).flatMap { file.objects[$0] }
        let configurations = (list?["buildConfigurations"] as? [String] ?? []).compactMap { file.objects[$0] }
        let projectList = (file.objects[file.rootObjectID]?["buildConfigurationList"] as? String)
            .flatMap { file.objects[$0] }
        let projectConfigurations = (projectList?["buildConfigurations"] as? [String] ?? [])
            .compactMap { file.objects[$0] }
        var hosts: [XcodeTargetKey] = []
        // A project's settings link for every target, but name no target's host.
        for configuration in projectConfigurations {
            guard let settings = settings(of: configuration, in: file),
                  let linked = linkedTargets(by: settings["OTHER_LDFLAGS"], index: index)
            else {
                return nil
            }
            hosts += linked
        }
        for configuration in configurations {
            guard let settings = settings(of: configuration, in: file),
                  let linked = linkedTargets(by: settings["OTHER_LDFLAGS"], index: index)
            else {
                return nil
            }
            hosts += linked
            for setting in ["TEST_HOST", "BUNDLE_LOADER"] {
                // A bundle loader is the test host, most often, which the other setting names.
                guard let value = settings[setting], !value.isEmpty, value != "$(TEST_HOST)" else {
                    continue
                }
                let bundle = value.split(separator: "/").map(String.init).last { component in
                    bundleExtensions.contains(component.pathExtension)
                }
                guard let bundle, !bundle.contains("$") else { return nil }
                let found = index.targets(makingProductNamed: bundle)
                guard !found.isEmpty else { return nil }
                hosts += found
            }
            if let name = settings["TEST_TARGET_NAME"], !name.isEmpty {
                let found = index.targets(named: name, preferring: project)
                guard !found.isEmpty else { return nil }
                hosts += found
            }
        }
        return hosts
    }

    /// The targets whose products the linker flags in `values` link by name; nil if one names a product by a
    /// variable. A name no target makes is a system's framework or library.
    static func linkedTargets(by value: String?, index: XcodeTargetIndex) -> [XcodeTargetKey]? {
        let arguments = (value ?? "")
            .split { $0 == " " || $0 == "\t" || $0 == "," }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        var linked: [XcodeTargetKey] = []
        var namesAFramework = false
        for argument in arguments where argument != "$(inherited)" {
            if namesAFramework {
                namesAFramework = false
                guard !argument.contains("$") else { return nil }
                linked += index.targets(makingProductNamed: argument + ".framework")
            } else if frameworkFlags.contains(argument) {
                namesAFramework = true
            } else if let flag = libraryFlags.first(where: { argument.hasPrefix($0) && argument.count > $0.count }) {
                let name = String(argument.dropFirst(flag.count))
                guard !name.contains("$") else { return nil }
                for product in ["lib\(name).a", "lib\(name).dylib", "\(name).framework"] {
                    linked += index.targets(makingProductNamed: product)
                }
            }
        }
        return linked
    }

    /// The followed settings of `configuration`, a build configuration of `file`: its own over those of the build
    /// configuration file it's based on, but the linker flags of both. Nil if that file can't be read.
    static func settings(of configuration: [String: Any], in file: ProjectFile) -> [String: String]? {
        guard let fromFiles = hostSettings(ofFileBehind: configuration, in: file) else { return nil }
        let own = (configuration["buildSettings"] as? [String: Any] ?? [:]).compactMapValues { value in
            value as? String ?? (value as? [String])?.joined(separator: " ")
        }
        var settings = fromFiles.merging(own) { _, own in own }
        settings["OTHER_LDFLAGS"] = joined(fromFiles["OTHER_LDFLAGS"], own["OTHER_LDFLAGS"])
        return settings
    }

    /// `first` and `second`, whichever there are, as one list of arguments.
    static func joined(_ first: String?, _ second: String?) -> String? {
        let both = [first, second].compactMap(\.self)
        return both.isEmpty ? nil : both.joined(separator: " ")
    }

    /// The host settings the build configuration file `configuration` is based on sets, with the files it includes,
    /// by name without conditions, its own over those it includes; empty without one, and nil if one can't be read,
    /// or is in a synced folder, where SwiftMutator doesn't look.
    static func hostSettings(
        ofFileBehind configuration: [String: Any],
        in file: ProjectFile
    ) -> [String: String]? {
        guard configuration["baseConfigurationReferenceAnchor"] == nil else { return nil }
        guard let reference = configuration["baseConfigurationReference"] as? String else { return [:] }
        guard let path = file.location(of: reference) else { return nil }
        return hostSettings(inFileAt: path, depth: 0)
    }

    static func hostSettings(inFileAt path: FilePath, depth: Int) -> [String: String]? {
        guard depth < 16, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let buildFile = XcodeBuildConditions.BuildFile(name: path.lastPathComponent, text: text, path: path)
        guard let included = XcodeBuildConditions.configurationFiles(includedBy: buildFile),
              let assigned = XcodeBuildConditions.buildSettings(in: buildFile)
        else {
            return nil
        }
        var settings: [String: String] = [:]
        // Linker flags are gathered from every file, as one may add to another's with `$(inherited)`.
        for include in included {
            guard let theirs = hostSettings(inFileAt: include, depth: depth + 1) else { return nil }
            let flags = joined(settings["OTHER_LDFLAGS"], theirs["OTHER_LDFLAGS"])
            settings.merge(theirs) { _, later in later }
            settings["OTHER_LDFLAGS"] = flags
        }
        for (name, value) in assigned where followedSettings.contains(name) {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ;"))
            settings[name] = name == "OTHER_LDFLAGS" ? joined(settings[name], trimmed) : trimmed
        }
        return settings
    }
}
