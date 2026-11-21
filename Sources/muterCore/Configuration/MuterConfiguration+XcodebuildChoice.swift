import Foundation

extension MuterConfiguration {
    /// This configuration with what xcodebuild opens, builds and tests on, from its keys (`xcodebuild`) and from the
    /// run's flags, `flags`, written into `testCommandArguments`, and its keys cleared, so a results header and a
    /// baseline's scope record them in `arguments` alone, which a resume compares. A flag replaces its key and every
    /// occurrence of its option in `arguments`: `--workspace` and `--project` replace either container. A key is added
    /// where `arguments` lack its option; one they give with another value is refused, as the run can't tell which is
    /// meant, and one they give with the same value leaves them as they are. `folder` is the project's, which a
    /// workspace or project is compared in. Also refused: any of them for a test command that isn't xcodebuild's,
    /// `workspace` with `project`, and a workspace or project named by an absolute path or by one that climbs out of
    /// the folder it is read in, as `../App/App.xcworkspace`, which would open the project rather than the copy
    /// SwiftMutator mutates.
    func choosingXcodebuildOptions(_ flags: XcodebuildChoice, in folder: String) throws -> Self {
        let keys = xcodebuild
        guard !keys.isEmpty || !flags.isEmpty else { return self }
        if let reason = xcodebuildChoiceRefused(keys: keys, flags: flags) {
            throw MuterError.configurationParsingError(reason: reason)
        }
        var arguments = try Self.choosingContainer(keys.container, flags.container, in: testCommandArguments, folder)
        arguments = try Self.choosingScheme(keys.scheme, flags.scheme, in: arguments)
        arguments = try Self.choosingDestinations(keys.destinations, flags.destinations, in: arguments)
        var copy = self
        copy.testCommandArguments = arguments
        copy.xcodebuild = XcodebuildChoice()
        return copy
    }

    /// Why `keys` and `flags` can't be used with this test command, or nil.
    private func xcodebuildChoiceRefused(keys: XcodebuildChoice, flags: XcodebuildChoice) -> String? {
        let given = Self.firstNamed(keys: keys, flags: flags)
        switch buildSystem {
        case .xcodebuild:
            break

        case .swift:
            return "\(given) is for an xcodebuild project: `swift test` has no scheme, destination, workspace or "
                + "project."

        case .unknown:
            return "\(given) is for an xcodebuild project, and `executable` isn't xcodebuild: set "
                + "`buildSystem: xcodebuild` if it runs xcodebuild."
        }
        if keys.workspace != nil, keys.project != nil {
            return "`workspace:` and `project:` can't both be given: xcodebuild opens one workspace or project."
        }
        let containers = [
            ("--workspace", flags.workspace), ("--project", flags.project),
            ("workspace:", keys.workspace), ("project:", keys.project),
        ]
        for case let (option, path?) in containers {
            let named = "`\(option) \(path)`"
            let problem: String
            if path.hasPrefix("/") || path.hasPrefix("~") {
                problem = "is an absolute path"
            } else if !Self.staysInside(path) {
                problem = "names one outside the project's folder"
            } else {
                continue
            }
            return "\(named) \(problem): name it relative to the project's folder, as "
                + "\(URL(fileURLWithPath: path).lastPathComponent), so the run opens the one in the copy "
                + "SwiftMutator mutates."
        }
        return nil
    }

    /// Whether the relative `path` stays below the folder it is read in, as `App.xcworkspace` and
    /// `Apps/../App.xcworkspace` do. One that climbs above it at any point, as `../App/App.xcworkspace` does even
    /// from a folder named `App`, leads out of the copy SwiftMutator mutates, which has another name, to the project.
    static func staysInside(_ path: String) -> Bool {
        var depth = 0
        for component in path.split(separator: "/") where component != "." {
            depth += component == ".." ? -1 : 1
            if depth < 0 {
                return false
            }
        }
        return true
    }

    /// The first flag given, else the first key, as a refusal names it: `--scheme`, or `scheme:`.
    private static func firstNamed(keys: XcodebuildChoice, flags: XcodebuildChoice) -> String {
        let named: [(String, Bool)] = [
            ("--workspace", flags.workspace != nil), ("--project", flags.project != nil),
            ("--scheme", flags.scheme != nil), ("--destination", flags.destinations != nil),
            ("workspace:", keys.workspace != nil), ("project:", keys.project != nil),
            ("scheme:", keys.scheme != nil), ("destination:", keys.destinations != nil),
        ]
        return "`\(named.first(where: \.1)?.0 ?? "destination:")`"
    }

    private static let containerOptions: Set = ["-workspace", "-project"]

    /// `arguments` with the flag's workspace or project in place of theirs, or else with the key's where they have
    /// none. Refused: a key that names another workspace or project than theirs, or the other kind.
    private static func choosingContainer(
        _ key: (option: String, path: String)?,
        _ flag: (option: String, path: String)?,
        in arguments: [String],
        _ folder: String
    ) throws -> [String] {
        let parsed = XcodebuildArguments(arguments)
        guard let chosen = flag ?? key else { return arguments }
        let written = parsed.options(named: containerOptions)
        guard flag == nil, !written.isEmpty else {
            return parsed.replacing(containerOptions, with: [chosen.option, chosen.path], placing: .after([]))
        }
        let keyName = chosen.option == "-workspace" ? "workspace:" : "project:"
        for argument in written {
            let shown = "`\(keyName) \(chosen.path)` and `\(argument.written.joined(separator: " "))` in `arguments`"
            guard argument.name == chosen.option else {
                throw MuterError.configurationParsingError(
                    reason: "\(shown) name a workspace and a project, and xcodebuild opens one: give it once, in "
                        + "`\(keyName)` or in `arguments`."
                )
            }
            guard samePath(argument.value ?? "", chosen.path, in: folder) else {
                let kind = chosen.option == "-workspace" ? "workspaces" : "projects"
                throw MuterError.configurationParsingError(
                    reason: "\(shown) name different \(kind): give it once, in `\(keyName)` or in `arguments`."
                )
            }
        }
        return arguments
    }

    /// `arguments` with the flag's scheme in place of theirs, or else with the key's where they have none, after the
    /// workspace or project. Refused: a key that names another scheme than theirs.
    private static func choosingScheme(_ key: String?, _ flag: String?, in arguments: [String]) throws -> [String] {
        let parsed = XcodebuildArguments(arguments)
        guard let chosen = flag ?? key else { return arguments }
        let written = parsed.options(named: ["-scheme"])
        guard flag == nil, !written.isEmpty else {
            return parsed.replacing(["-scheme"], with: ["-scheme", chosen], placing: .after(containerOptions))
        }
        if let other = written.first(where: { $0.value != chosen }) {
            throw MuterError.configurationParsingError(
                reason: "`scheme: \(chosen)` and `\(other.written.joined(separator: " "))` in `arguments` name "
                    + "different schemes: give it once, in `scheme:` or in `arguments`."
            )
        }
        return arguments
    }

    /// `arguments` with the flags' destinations in place of all of theirs, where the first was, or else with the key's
    /// where they have none, before the first action. Refused: a key whose destinations aren't theirs, in their order,
    /// each compared by its `key=value` pairs in any order.
    private static func choosingDestinations(
        _ key: [String]?,
        _ flag: [String]?,
        in arguments: [String]
    ) throws -> [String] {
        let parsed = XcodebuildArguments(arguments)
        guard let chosen = flag ?? key else { return arguments }
        let written = parsed.options(named: ["-destination"])
        guard flag == nil, !written.isEmpty else {
            let replacement = chosen.flatMap { ["-destination", $0] }
            return parsed.replacing(["-destination"], with: replacement, placing: .beforeTheFirstAction)
        }
        guard written.map({ pairs(of: $0.value ?? "") }) == chosen.map(pairs(of:)) else {
            let keyShown = chosen.count == 1 ? "`destination: \(chosen[0])`" : "`destination:`'s \(chosen.count) "
                + "destinations"
            let argumentsShown = written.map { $0.written.joined(separator: " ") }.joined(separator: " ")
            throw MuterError.configurationParsingError(
                reason: "\(keyShown) and `\(argumentsShown)` in `arguments` name different destinations: give them "
                    + "once, in `destination:` or in `arguments`."
            )
        }
        return arguments
    }

    /// A destination's `key=value` pairs, each with the spaces around its key and value trimmed, so
    /// `platform=iOS Simulator,name=iPhone 17` and `name=iPhone 17, platform=iOS Simulator` are one destination.
    static func pairs(of destination: String) -> Set<String> {
        Set(destination.split(separator: ",").map { pair in
            pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "=")
        })
    }

    /// Whether two paths relative to `folder` name one file, as `App.xcworkspace` and `./App.xcworkspace` do.
    static func samePath(_ one: String, _ other: String, in folder: String) -> Bool {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let standardized = { (path: String) in URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path }
        return standardized(one) == standardized(other)
    }
}

extension MuterConfiguration {
    /// The `workspace`, `project`, `scheme` and `destination` keys, each a string, and `destination` also a list of
    /// them, kept as a list. Throws on a blank value, an empty list or a blank entry in it, and on a value of another
    /// type, so a typo is a configuration error rather than "unset". `workspace` with `project` is refused once the
    /// run's flags are in (`choosingXcodebuildOptions(_:in:)`), not here, as a results header must still read.
    static func xcodebuildChoice(in container: KeyedDecodingContainer<CodingKeys>) throws -> XcodebuildChoice {
        XcodebuildChoice(
            workspace: try text(forKey: .workspace, naming: "a workspace's path", in: container),
            project: try text(forKey: .project, naming: "a project's path", in: container),
            scheme: try text(forKey: .scheme, naming: "a scheme's name", in: container),
            destinations: try destinations(forKey: .destination, in: container)
        )
    }

    /// Writes the keys `xcodebuildChoice(in:)` reads, those set: `destination` as a list.
    func encodeXcodebuildChoice(in container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(xcodebuild.workspace, forKey: .workspace)
        try container.encodeIfPresent(xcodebuild.project, forKey: .project)
        try container.encodeIfPresent(xcodebuild.scheme, forKey: .scheme)
        try container.encodeIfPresent(xcodebuild.destinations, forKey: .destination)
    }

    private static func text(
        forKey key: CodingKeys,
        naming what: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        guard let written = try? container.decode(String.self, forKey: key), !written.trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be \(what). Leave it out to keep what arguments give."
            )
        }
        return written
    }

    private static func destinations(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String]? {
        guard container.contains(key) else { return nil }
        let one = try? container.decode(String.self, forKey: key)
        let written = one.map { [$0] } ?? (try? container.decode([String].self, forKey: key))
        guard let written, !written.isEmpty, !written.contains(where: \.trimmed.isEmpty) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a destination, as -destination takes it, or a list of "
                    + "them, none blank. Leave it out to keep what arguments give."
            )
        }
        return written
    }
}
