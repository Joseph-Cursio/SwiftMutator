import Foundation
import SwiftIfConfig

/// Why SwiftMutator couldn't tell what a project's build compiles with.
struct BuildConditionsUnavailable: Error, Equatable {
    /// To follow "SwiftMutator couldn't tell which `#if` branches the build compiles: ".
    let reason: String
}

/// What a project's build compiles with, for each file where the build system says which targets hold it.
struct ProjectBuildConditions: Equatable, Sendable {
    /// For any file, by every target's conditions: an `#if` is decided only where they all agree.
    let everyTarget: BuildConditions
    /// The custom conditions of the targets that hold a file, by its path relative to the project, for a build system
    /// that says. xcodebuild says only after a build, in the lists of the files each target compiled.
    var customConditionsOfFile: [FilePath: [Set<String>]] = [:]
    /// The files among `customConditionsOfFile`'s whose targets' conditions are all there is to them, with nothing
    /// else that may set one: a name none of the targets sets is unset, though `everyTarget` leaves it undecided.
    var filesWithAllTheirConditions: Set<FilePath> = []

    /// What the build compiles the file at `path`, relative to the project, with.
    func conditions(ofFile path: FilePath) -> BuildConditions {
        var conditions = everyTarget
        if let targets = customConditionsOfFile[path], !targets.isEmpty {
            conditions.customConditions = targets
            if filesWithAllTheirConditions.contains(path) {
                conditions.undecidedConditions = []
                conditions.anyConditionMayBeSetElsewhere = false
            }
        }
        return conditions
    }
}

/// The compiler's version in what `swift --version` or `swiftc --version` prints, as `compiler(…)` compares it: the
/// `6.2.1` of `Swift version 6.2.1 (swift-6.2.1-RELEASE)` or `Apple Swift version 6.2.1 (swiftlang-…)`. Nil for any
/// other, as a development snapshot's `6.3-dev`, which may not compare as what it says.
func compilerVersion(inVersionOutput output: String) -> VersionTuple? {
    guard let start = output.range(of: "Swift version ")?.upperBound else { return nil }
    let version = output[start...].prefix { !$0.isWhitespace }
    guard version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
    return VersionTuple(parsing: String(version))
}

/// The conditions among compiler flags: `-DNAME`, and `-D NAME` as two flags. A flag that `-Xcc`, `-Xllvm`, `-Xlinker`
/// or `-Xclang-linker` passes on is another tool's, so `-Xcc -DNAME` defines a C macro, not a condition. The frontend
/// takes `-D` as the driver does, and each flag `-Xfrontend` passes it is read in turn, as the frontend reads them:
/// so `-Xfrontend -DNAME` and `-Xfrontend -D -Xfrontend NAME` are conditions, and `-Xfrontend -Xcc -Xfrontend -DNAME`
/// isn't.
func customConditions(inSwiftFlags flags: [String]) -> Set<String> {
    var conditions: Set<String> = []
    var frontendFlags: [String] = []
    var index = 0
    while index < flags.count {
        let flag = flags[index]
        if flag == "-Xfrontend" {
            if index + 1 < flags.count {
                frontendFlags.append(flags[index + 1])
            }
            index += 2
            continue
        }
        if passedToAnotherTool.contains(flag) {
            index += 2
            continue
        }
        if flag == "-D" {
            if index + 1 < flags.count {
                conditions.insert(flags[index + 1])
            }
            index += 2
            continue
        }
        if flag.hasPrefix("-D") {
            conditions.insert(String(flag.dropFirst(2)))
        }
        index += 1
    }
    // The frontend takes no `-Xfrontend` of its own, so these hold none.
    return frontendFlags.isEmpty ? conditions : conditions.union(customConditions(inSwiftFlags: frontendFlags))
}

/// The options that pass the flag after them to a tool other than the Swift compiler.
private let passedToAnotherTool: Set = ["-Xcc", "-Xllvm", "-Xlinker", "-Xclang-linker"]
