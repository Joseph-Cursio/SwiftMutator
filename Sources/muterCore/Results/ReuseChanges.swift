import Foundation

/// What changed in the project since one session of the run whose results `--reuse` starts from, split by what each
/// change can make wrong. A change to a file other than a test file can change any mutant's result, so it retests
/// every result, unless a `--reuse-ignoring` glob lets it through. A test file's change is never let through: it
/// retests every survivor, and every kill that no unchanged test still holds (`killHolds(_:)`).
struct ReuseChanges: Equatable {
    /// Changed, added or removed files other than test files, that no glob matches.
    let otherFiles: [ProjectTree.FileChange]
    /// The paths of the other files' changes that a glob let through.
    let waived: [String]
    /// Changed, added or removed test files.
    let testFiles: [ProjectTree.FileChange]
    /// The text of every Swift test file this run has, by path, as the project's copy holds it; only read when test
    /// files changed. A file that can't be read is left out.
    let testSources: [String: String]
    /// The files of the session, and of this run, each one's SHA-256 by its path.
    let recordedFiles: [String: String]
    let currentFiles: [String: String]
    /// The paths of `recordedFiles` and of `currentFiles` by their files' names, which a test's issue names alone.
    private let recordedPathsByName: [String: [String]]
    private let currentPathsByName: [String: [String]]

    /// Whether nothing changed at all, let through or not.
    var isEmpty: Bool {
        otherFiles.isEmpty && waived.isEmpty && testFiles.isEmpty
    }
}

extension ReuseChanges {
    /// The changes from the session's tree `recorded` to this run's, `current`, split, with `globs` matched against the
    /// files other than test files only. `readSource` gives a file's text by its path relative to the project, as the
    /// copy holds it, or nil if it can't be read. Changes to a local package's own tests, outside the project, are left
    /// out: the project never builds them.
    init(
        from recorded: ProjectTree,
        to current: ProjectTree,
        waiving globs: [String],
        readSource: (String) -> String?
    ) {
        let changes = current.changes(since: recorded)
            .filter { !($0.path.hasPrefix("../") && Self.isInTestFolder($0.path)) }
        let testPaths = Set(changes.filter { $0.kind != .removed && Self.isTestFile($0.path, readSource: readSource) }
            .map(\.path))
        let testFiles = changes.filter { testPaths.contains($0.path) }
        // A removed file's text is gone, so nothing shows whether it was a test or a fixture. One that may have been
        // either counts as another file, which no glob lets through.
        let others = changes.filter { !testPaths.contains($0.path) }
        let mayHaveBeenATest = { (change: ProjectTree.FileChange) in
            change.kind == .removed && change.path.hasSuffix(".swift")
                && (Self.isInTestFolder(change.path) || change.path.hasSuffix("Tests.swift"))
        }
        let split = others.filter { !mayHaveBeenATest($0) }.partition(by: globs)
        var sources: [String: String] = [:]
        if !testFiles.isEmpty {
            for path in current.files.keys
                where path.hasSuffix(".swift") && Self.isTestFile(path, readSource: readSource) {
                sources[path] = readSource(path)
            }
        }
        otherFiles = (others.filter(mayHaveBeenATest) + split.unwaived).sorted { $0.path < $1.path }
        waived = split.waived.map(\.path)
        self.testFiles = testFiles
        testSources = sources
        recordedFiles = recorded.files
        currentFiles = current.files
        recordedPathsByName = Self.pathsByName(recorded.files)
        currentPathsByName = Self.pathsByName(current.files)
    }

    /// Whether `path`, relative to the project, is a test file: a Swift file that imports Testing or XCTest, as
    /// `readSource` shows, in a test folder, one named `Tests` or ending in `Tests`, such as `MyAppTests`, or outside
    /// them if its name ends in `Tests.swift`. A test's fixtures and resources aren't, Swift ones included, nor are
    /// helpers that import neither: a test file can't name what it reads from them, so their changes count as other
    /// files'.
    static func isTestFile(_ path: String, readSource: (String) -> String?) -> Bool {
        guard path.hasSuffix(".swift"), isInTestFolder(path) || path.hasSuffix("Tests.swift"),
              let text = readSource(path)
        else {
            return false
        }
        return text.range(
            of: #"(?m)^\s*(@testable\s+)?import\s+(Testing|XCTest)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Whether `record`'s kill is still a kill after the test files' changes: at least one of the tests it names holds.
    /// Every named test really failed, so one that is unchanged, and depends on nothing that changed, fails again.
    ///
    /// A test holds if its issue's file, by its name alone, is one and the same unchanged file in both trees, and that
    /// file still declares it; if no changed or added test file names it; and if that file names no changed, added or
    /// removed test file's type, by the file's name. A test whose issues are recorded in a helper that doesn't declare
    /// it doesn't hold. Without named tests, as from XCTest, whose names carry no file, or from a run whose failed-test
    /// lines weren't reliable, a kill doesn't hold.
    func killHolds(_ record: MutantResult) -> Bool {
        guard let killers = record.killedBy else { return false }
        return killers.contains(where: holds)
    }

    private func holds(_ test: FailedTestLine.FailedTest) -> Bool {
        guard let file = FailedTestLine.TestIdentity(test).file,
              let path = Self.onlyPath(named: file, in: recordedPathsByName),
              Self.onlyPath(named: file, in: currentPathsByName) == path,
              recordedFiles[path] == currentFiles[path],
              let text = testSources[path],
              let name = Searched(test.name),
              name.isDeclared(in: text)
        else {
            return false
        }
        let changedTexts = testFiles.filter { $0.kind != .removed }.map { testSources[$0.path] }
        // One that couldn't be read could name it.
        if changedTexts.contains(where: { $0.map { name.isNamed(in: $0) } ?? true }) {
            return false
        }
        // A file's type is its name's, up to a `+`: `ParsingTests+Helpers.swift` extends `ParsingTests`.
        let changedTypes = testFiles.map { change in
            String((change.path as NSString).lastPathComponent.prefix { $0 != "+" && $0 != "." })
        }
        return !changedTypes.contains { Searched.containsIdentifier($0, in: text) }
    }

    /// Whether some folder of `path`, but its last component, is a test folder.
    private static func isInTestFolder(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0.hasSuffix("Tests") }
    }

    private static func pathsByName(_ files: [String: String]) -> [String: [String]] {
        Dictionary(grouping: files.keys) { ($0 as NSString).lastPathComponent }
    }

    /// The only path whose file's name is `name`; nil if there is none, or more than one.
    private static func onlyPath(named name: String, in pathsByName: [String: [String]]) -> String? {
        guard let paths = pathsByName[name], paths.count == 1 else { return nil }
        return paths.first
    }

    /// What a test's name has in the text that declares it: a display name, in its quotes, or a function's name; a
    /// suite's issue, `Suite "Parsing"` or `Suite ParsingTests`, its suite's.
    private enum Searched {
        case displayName(String)
        case function(String)
        case type(String)

        init?(_ name: String) {
            var name = Substring(name)
            let isSuite = name.hasPrefix("Suite ")
            if isSuite {
                name = name.dropFirst("Suite ".count)
            }
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count > 2 {
                self = .displayName(String(name))
                return
            }
            let identifier = String(name.prefix { $0 != "(" })
            guard !identifier.isEmpty, identifier.allSatisfy(Self.isIdentifierCharacter) else { return nil }
            self = isSuite ? .type(identifier) : .function(identifier)
        }

        /// Whether `text` declares the test, or the suite.
        func isDeclared(in text: String) -> Bool {
            switch self {
            case let .displayName(quoted):
                return text.contains(quoted)
            case let .function(name):
                let declaration = #"\bfunc\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
                return text.range(of: declaration, options: .regularExpression) != nil
            case let .type(name):
                return Self.containsIdentifier(name, in: text)
            }
        }

        /// Whether `text` names the test, or the suite, at all.
        func isNamed(in text: String) -> Bool {
            switch self {
            case let .displayName(quoted):
                return text.contains(quoted)
            case let .function(name), let .type(name):
                return Self.containsIdentifier(name, in: text)
            }
        }

        /// Whether `identifier` is in `text` as a whole identifier, not inside a longer one.
        static func containsIdentifier(_ identifier: String, in text: String) -> Bool {
            guard !identifier.isEmpty else { return false }
            var searched = text.startIndex..<text.endIndex
            while let found = text.range(of: identifier, range: searched) {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if !(before.map(isIdentifierCharacter) ?? false), !(after.map(isIdentifierCharacter) ?? false) {
                    return true
                }
                searched = found.upperBound..<text.endIndex
            }
            return false
        }

        static func isIdentifierCharacter(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }
    }
}
