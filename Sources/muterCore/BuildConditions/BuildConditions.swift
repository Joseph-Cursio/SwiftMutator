import SwiftDiagnostics
import SwiftIfConfig
import SwiftSyntax

/// What the build a run tests compiles with, as far as SwiftMutator can tell, for working out which `#if` branches it
/// leaves out. Anything it can't tell is left undecided, and undecided code keeps its mutants: a branch wrongly taken
/// for inactive would silently lose real mutants, where one wrongly kept gets mutants that only coverage can then
/// filter out, as it did before this pass.
struct BuildConditions: Equatable, Sendable {
    /// The platform the build is for; nil if SwiftMutator can't tell, as for a cross-compilation.
    var platform: Platform?
    /// The custom conditions set for each target the code may be in: `-D` flags and the like. A condition is set if
    /// every target sets it, and not set if none does and nothing else might. For a condition only some targets set,
    /// which target's build a branch belongs to decides, so it is undecided.
    var customConditions: [Set<String>]
    /// The custom conditions no target here sets, but that something else might: a package's traits, or a name a build
    /// file mentions, which may be a setting of a target xcodebuild didn't report.
    var undecidedConditions: Set<String> = []
    /// The compiler's version, as `compiler(…)` compares it: the one `swift --version` prints. Nil if SwiftMutator
    /// can't tell, as when the command picks a toolchain of its own.
    var compiler: VersionTuple?
    /// The language version `swift(…)` compares with, which the language mode sets: 5.10 in Swift 5 mode, and in Swift
    /// 6 mode the compiler's own version. Nil if SwiftMutator can't tell, as when the targets' modes differ.
    var language: VersionTuple?

    struct Platform: Equatable, Sendable {
        /// As `os(…)` spells it.
        let system: String
        /// As `targetEnvironment(…)` spells it: `simulator` or `macCatalyst`.
        var environment: String?
        /// As `arch(…)` spells them. A build for several compiles a branch for any of them.
        let architectures: Set<String>
        /// nil if SwiftMutator couldn't list the SDK's.
        var modules: SDKModules?
    }

    /// What `canImport` can say from the SDKs. A module in neither set may still be a package's, or a target's in the
    /// project, so it is undecided. A module in `absent` is left to another platform's SDK, as UIKit is for macOS.
    struct SDKModules: Equatable, Sendable {
        let present: Set<String>
        let absent: Set<String>
    }

    /// What an `#if` asks and the build can't answer. `SwiftIfConfig` reports it as an error for the condition.
    private struct Undecided: Error, CustomStringConvertible {
        let description: String
    }

    /// The functions in a condition that the `BuildConfiguration` protocol asks for without letting it decline, and
    /// that this build can't answer: `_compiler_version`, whose old build numbers SwiftMutator doesn't look up, the
    /// atomic widths, and the language and compiler versions, pointer width and byte order where it couldn't tell them.
    /// A condition that calls one is undecided.
    private var unanswerable: Set<String> {
        var names: Set = ["_compiler_version", "_hasAtomicBitWidth"]
        if language == nil {
            names.insert("swift")
        }
        if compiler == nil {
            names.insert("compiler")
        }
        if platform?.pointerBitWidth == nil {
            names.insert("_pointerBitWidth")
        }
        if platform?.endianness == nil {
            names.insert("_endian")
        }
        return names
    }

    /// The ranges of the code in `tree` that an `#if` leaves out of this build. Sorted, and none holds another.
    func inactiveRegions(in tree: some SyntaxProtocol) -> [Range<AbsolutePosition>] {
        let visitor = InactiveRegionVisitor(conditions: self)
        visitor.walk(tree)
        return visitor.regions
    }

    /// Whether `condition` holds in this build; nil if it can't be told.
    fileprivate func holds(_ condition: ExprSyntax) -> Bool? {
        let unanswerable = unanswerable
        // By the identifier's name, so that `` `swift`(>=5) `` is found too.
        let isUnanswerable = condition.tokens(viewMode: .sourceAccurate).contains {
            unanswerable.contains($0.identifier?.name ?? $0.text)
        }
        guard !isUnanswerable else { return nil }

        let (state, _, diagnostics) = IfConfigRegionState.evaluating(condition, in: self)
        // On an error it gives false, and `!` then makes that true, so its answer means nothing.
        guard !diagnostics.contains(where: { $0.diagMessage.severity == .error }) else { return nil }
        return state == .active
    }
}

extension BuildConditions: BuildConfiguration {
    func isCustomConditionSet(name: String) throws -> Bool {
        // `$AsyncAwait` asks whether the compiler has a feature, as `hasFeature(…)` does: it is no condition a build
        // sets, and it holds wherever the feature is on.
        guard !name.hasPrefix("$") else {
            throw Undecided(description: "whether the compiler has \(name.dropFirst())")
        }
        if !customConditions.isEmpty, customConditions.allSatisfy({ $0.contains(name) }) {
            return true
        }
        // Xcode and SwiftPM set such names themselves, for some targets, and report them nowhere.
        let isTheBuildSystems = name.hasPrefix("SWIFT_")
        guard !isTheBuildSystems,
              !customConditions.isEmpty,
              !customConditions.contains(where: { $0.contains(name) }),
              !undecidedConditions.contains(name)
        else {
            throw Undecided(description: "whether \(name) is set")
        }
        return false
    }

    func hasFeature(name: String) throws -> Bool {
        throw Undecided(description: "whether the compiler has \(name)")
    }

    func hasAttribute(name: String) throws -> Bool {
        throw Undecided(description: "whether the compiler has \(name)")
    }

    func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        let name = importPath.map(\.1).joined(separator: ".")
        // A submodule or a version takes more than the SDK's folders can say.
        guard importPath.count == 1, case .unversioned = version, let modules = platform?.modules else {
            throw Undecided(description: "whether \(name) can be imported")
        }
        if modules.present.contains(name) {
            return true
        }
        guard modules.absent.contains(name) else {
            throw Undecided(description: "whether \(name) can be imported")
        }
        return false
    }

    func isActiveTargetOS(name: String) throws -> Bool {
        let platform = try knownPlatform()
        // `os(OSX)` is the old name of `os(macOS)`, and `os(xrOS)` that of `os(visionOS)`.
        let aliases = ["OSX": "macOS", "xrOS": "visionOS"]
        return (aliases[name] ?? name) == platform.system
    }

    func isActiveTargetArchitecture(name: String) throws -> Bool {
        let architectures = try knownPlatform().architectures
        guard architectures.contains(name) else {
            // `arch(arm64)` holds in an arm64e build too.
            guard !architectures.contains("arm64e") else {
                throw Undecided(description: "whether the architecture is \(name)")
            }
            return false
        }
        guard architectures.count == 1, name != "arm64e" else {
            throw Undecided(description: "whether the architecture is \(name)")
        }
        return true
    }

    func isActiveTargetEnvironment(name: String) throws -> Bool {
        try knownPlatform().environment == name
    }

    func isActiveTargetRuntime(name: String) throws -> Bool {
        let platform = try knownPlatform()
        return name == (Self.applePlatforms.contains(platform.system) ? "_ObjC" : "_Native")
    }

    func isActiveTargetPointerAuthentication(name: String) throws -> Bool {
        throw Undecided(description: "whether pointers are authenticated with \(name)")
    }

    func isActiveTargetObjectFormat(name: String) throws -> Bool {
        let platform = try knownPlatform()
        return name == (Self.applePlatforms.contains(platform.system) ? "MachO" : "ELF")
    }

    // The `unanswerable` functions ask these, and a condition that calls one this build can't answer is never
    // evaluated, so the placeholders are never read.
    var targetPointerBitWidth: Int { platform?.pointerBitWidth ?? 64 }
    var targetAtomicBitWidths: [Int] { [] }
    var endianness: Endianness { platform?.endianness ?? .little }
    var languageVersion: VersionTuple { language ?? VersionTuple(0) }
    var compilerVersion: VersionTuple { compiler ?? VersionTuple(0) }

    private static let applePlatforms: Set = ["macOS", "iOS", "tvOS", "watchOS", "visionOS", "DriverKit"]

    private func knownPlatform() throws -> Platform {
        guard let platform else {
            throw Undecided(description: "which platform the build is for")
        }
        return platform
    }
}

extension BuildConditions.Platform {
    /// The pointer width `_pointerBitWidth(…)` asks for: 64 if every architecture is 64-bit; nil otherwise. A 32-bit
    /// build is left undecided, as its macros and plugins are built for the host, which is 64-bit, in the same build.
    var pointerBitWidth: Int? {
        !architectures.isEmpty && architectures.isSubset(of: Self.sixtyFourBit) ? 64 : nil
    }

    /// The byte order `_endian(…)` asks for: little if every architecture is one SwiftMutator knows, as all of those
    /// are; nil otherwise.
    var endianness: Endianness? {
        !architectures.isEmpty && architectures.isSubset(of: Self.sixtyFourBit.union(Self.thirtyTwoBit)) ? .little : nil
    }

    /// As `arch(…)`, Xcode's `ARCHS` and SwiftPM's host spell them. All are little-endian.
    private static let sixtyFourBit: Set = ["arm64", "arm64e", "x86_64", "aarch64"]
    private static let thirtyTwoBit: Set = ["arm64_32", "armv7k", "armv7", "armv7s", "i386"]
}

/// Finds the `#if` clauses the build leaves out. `SwiftIfConfig`'s own `configuredRegions` has no "don't know": after a
/// condition it can't evaluate it takes the next clause as active, so the `#else` of one would read as the branch that
/// compiles, and the branch before it as left out.
private final class InactiveRegionVisitor: SyntaxVisitor {
    private let conditions: BuildConditions
    private(set) var regions: [Range<AbsolutePosition>] = []

    init(conditions: BuildConditions) {
        self.conditions = conditions
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        // Once a clause's condition holds, whichever clause compiles, those after it don't.
        var anEarlierClauseCompiles = false
        for clause in node.clauses {
            let holds = clause.condition.map(conditions.holds) ?? true
            if anEarlierClauseCompiles || holds == false {
                if let elements = clause.elements {
                    regions.append(elements.position ..< elements.endPosition)
                }
                continue
            }
            // A clause that may compile can hold `#if`s that are decided, as an `os(…)` is inside a `canImport(…)`.
            if let elements = clause.elements {
                walk(elements)
            }
            anEarlierClauseCompiles = holds == true
        }
        return .skipChildren
    }
}
