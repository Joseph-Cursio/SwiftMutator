import Foundation

/// The build phases of an Xcode project that run SwiftLint, and what turning it off in them did. Each mutated file
/// starts with `// swiftlint:disable all` (`DisableLintersRewriter`), so in the copy such a phase only costs time on
/// each of its builds, and can fail them, as `swiftlint --strict` does with a rule against blanket disables. Only the
/// commands that run SwiftLint are turned off, each with `: ` before it (`SwiftLintCommands`), so the rest of each
/// script still runs, and a turned-off command is found again and left as it is.
struct SwiftLintPhases: Equatable {
    struct Phase: Equatable {
        /// The project, by its path relative to the copy, as `App/App.xcodeproj`.
        let project: String
        /// The phase's name, as Xcode shows it: `Run Script` when it has none.
        let name: String
        /// The targets that build with it, by name, in the project's order.
        let targets: [String]

        /// `App.xcodeproj: Run SwiftLint, in target App`.
        var shown: String {
            let allTargets = targets.isEmpty
                ? ""
                : ", in \(targets.count == 1 ? "target" : "targets") \(targets.joined(separator: ", "))"
            return "\(project): \(name)\(allTargets)"
        }
    }

    /// The phases with a command that ran SwiftLint and runs it no more. Another command of the phase may still run
    /// it some other way, as through a variable, which a name in an `echo` or a `which` can't be told from.
    var turnedOff: [Phase] = []
    /// The phases whose script names SwiftLint, but in no command found to run it, or to have it off already, as one
    /// that runs a script of its own, or with a shell other than `sh`, `bash`, `zsh`, `ksh` or `dash`: it may still
    /// run there.
    var leftRunning: [Phase] = []
    /// The project files, as `App/App.xcodeproj`, that name SwiftLint but can't be read, or written.
    var unreadProjects: [String] = []

    var isEmpty: Bool {
        turnedOff.isEmpty && leftRunning.isEmpty && unreadProjects.isEmpty
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            turnedOff: lhs.turnedOff + rhs.turnedOff,
            leftRunning: lhs.leftRunning + rhs.leftRunning,
            unreadProjects: lhs.unreadProjects + rhs.unreadProjects
        )
    }

    /// Whether `path`, relative to a folder, is an Xcode project's file, `*.xcodeproj/project.pbxproj`.
    static func isProjectFile(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count >= 2 && components.last == "project.pbxproj"
            && components[components.count - 2].hasSuffix(".xcodeproj")
    }

    /// Turns SwiftLint off in the project file at `url`, whose project is shown as `project`, and says what it did.
    /// The file is written only when it changes, and atomically: a new file takes its place, so a link in the copy to
    /// a file outside it, such as the project's own, is replaced rather than written through.
    static func turnOff(inProjectFileAt url: URL, shownAs project: String) -> Self {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Self() }
        let bytes = [UInt8](data)
        let (changed, phases) = turningOff(in: bytes, project: project)
        guard changed != bytes else { return phases }
        do {
            try Data(changed).write(to: url, options: .atomic)
            return phases
        } catch {
            return Self(unreadProjects: [project])
        }
    }

    /// The shells whose scripts are read, by name: `:` is a command of each.
    static let shells: Set = ["sh", "bash", "zsh", "ksh", "dash"]

    /// `bytes`, a project file's, with SwiftLint turned off in each of its shell script build phases, and what was
    /// done. Every other byte is left as it was; a script Xcode wrote without quotes is quoted once it is changed.
    static func turningOff(in bytes: [UInt8], project: String) -> (bytes: [UInt8], phases: Self) {
        guard let file = XcodeProjectFile(bytes) else {
            let named = String(lossyUTF8: bytes).lowercased().contains("swiftlint")
            return (bytes, Self(unreadProjects: named ? [project] : []))
        }
        let targets = targetsOfPhases(in: file)
        var phases = Self()
        var insertions: [(offset: Int, text: String)] = []
        for (identifier, object) in file.objects where object["isa"]?.string == "PBXShellScriptBuildPhase" {
            guard let script = object["shellScript"]?.text else { continue }
            let decoded = script.isQuoted
                ? XcodeProjectFile.decodedBytes(of: script.range, in: bytes)
                : script.range.map { (bytes[$0], $0) }
            let shell = (object["shellPath"]?.string ?? "/bin/sh").split(separator: "/").last.map(String.init) ?? ""
            let found = shells.contains(shell)
                ? SwiftLintCommands.find(in: decoded.map(\.byte))
                : SwiftLintCommands.Found()
            let phase = Phase(
                project: project,
                name: object["name"]?.string ?? "Run Script",
                targets: targets[identifier] ?? []
            )
            // A phase whose commands were all off already, as the project itself wrote them, was turned off by no one
            // here, and runs SwiftLint no more.
            guard !found.running.isEmpty else {
                if found.turnedOff == 0, script.value.lowercased().contains("swiftlint") {
                    phases.leftRunning.append(phase)
                }
                continue
            }
            phases.turnedOff.append(phase)
            if !script.isQuoted {
                insertions.append((script.range.lowerBound, "\""))
            }
            insertions += found.running.map { (decoded[$0].offset, SwiftLintCommands.prefix) }
            if !script.isQuoted {
                insertions.append((script.range.upperBound, "\""))
            }
        }
        return (inserting(insertions, into: bytes), phases)
    }

    /// The names of the targets that build with each phase, by the phase's identifier.
    private static func targetsOfPhases(in file: XcodeProjectFile) -> [String: [String]] {
        var targets: [String: [String]] = [:]
        for (_, object) in file.objects {
            guard let phases = object["buildPhases"], let name = object["name"]?.string else { continue }
            for phase in phases.items.compactMap(\.string) {
                targets[phase, default: []].append(name)
            }
        }
        return targets
    }

    /// `bytes` with each text inserted before the byte at its offset, those at the same offset in the order given.
    private static func inserting(_ insertions: [(offset: Int, text: String)], into bytes: [UInt8]) -> [UInt8] {
        guard !insertions.isEmpty else { return bytes }
        let sorted = insertions.enumerated()
            .sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
            .map(\.element)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + insertions.count * 2)
        var copied = 0
        for insertion in sorted {
            result += bytes[copied ..< insertion.offset]
            result += Array(insertion.text.utf8)
            copied = insertion.offset
        }
        result += bytes[copied...]
        return result
    }
}
