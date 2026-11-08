import Foundation

/// The SARIF report (`-f sarif`), for GitHub code scanning: each mutant the tests didn't kill, at its place in its
/// file, by its operator. A survivor and a timeout are warnings, as the score counts both as survivors, and a mutant
/// no test reached is a note. Kills and build errors aren't results. The same for the same outcome and the same files:
/// sorted keys, and results by path, line, column and operator.
struct SarifReporter: Reporter {
    /// How many results GitHub takes from one run, past which it rejects the file. It shows only the 5,000 most
    /// severe of them, which putting the warnings first keeps.
    static let mostResultsOnGitHub = 25_000
    static let informationUri = "https://github.com/Joseph-Cursio/SwiftMutator"
    /// Where the files' relative paths are: the work tree the project is in, or the project's folder outside one.
    static let sourceRoot = "%SRCROOT%"

    @Dependency(\.readSourceFile)
    private var readSourceFile: ReadFile
    @Dependency(\.projectInWorkTree)
    private var projectInWorkTree: ProjectInWorkTree
    /// The version the report names, which a test fixes so that a release doesn't change its output.
    private let swiftMutatorVersion: String
    /// How many results the report holds at most, survivors first; a test gives a few.
    private let mostResults: Int

    init(swiftMutatorVersion: String = version, mostResults: Int = mostResultsOnGitHub) {
        self.swiftMutatorVersion = swiftMutatorVersion
        self.mostResults = mostResults
    }

    func report(from outcome: MutationTestOutcome) -> String {
        SortedJSON.encoded(sarifLog(of: outcome))
    }

    /// The log of `outcome`: its first `mostResults` results, warnings before notes, then sorted. A file is read as
    /// it is now, for each mutant's columns and the line its fingerprint is made from. Its paths are from the root of
    /// the work tree the project is in, as GitHub reads a relative path from the repository's root.
    func sarifLog(of outcome: MutationTestOutcome) -> SarifLog {
        let found = SarifFinding.all(of: outcome, reading: readSourceFile)
        let place = outcome.projectPath.isEmpty ? nil : projectInWorkTree(outcome.projectPath)
        let root = place?.root ?? (outcome.projectPath.isEmpty ? nil : outcome.projectPath)
        let projectFolder = place?.projectFolder ?? ""
        let warnings = found.filter { $0.level == .warning }.sorted()
        let notes = found.filter { $0.level == .note }.sorted()
        let kept = (warnings + notes).prefix(max(0, mostResults)).sorted()
        let leftOut = found.count - kept.count
        let rules = Set(kept.map(\.operatorId)).sorted { $0.rawValue < $1.rawValue }
        let ruleIndices = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1, $0) })
        let run = SarifLog.Run(
            tool: SarifLog.Tool(driver: SarifLog.Driver(
                name: "SwiftMutator",
                version: swiftMutatorVersion,
                informationUri: Self.informationUri,
                rules: rules.map(Self.rule)
            )),
            invocations: [
                SarifLog.Invocation(
                    executionSuccessful: true,
                    toolExecutionNotifications: leftOut > 0 ? [notification(leftOut: leftOut, of: found.count)] : nil
                ),
            ],
            originalUriBaseIds: root.map { root in
                [
                    Self.sourceRoot: SarifLog.ArtifactLocation(
                        uri: URL(fileURLWithPath: root, isDirectory: true).absoluteString,
                        uriBaseId: nil
                    ),
                ]
            },
            columnKind: "utf16CodeUnits",
            results: kept.map {
                $0.result(ruleIndex: ruleIndices[$0.operatorId] ?? -1, projectFolder: projectFolder)
            },
            properties: leftOut > 0 ? SarifLog.Properties(resultsLeftOut: leftOut) : nil
        )
        return SarifLog(schema: SarifLog.schemaURI, version: "2.1.0", runs: [run])
    }

    /// An operator as a rule: its id, its name in words, and what it does.
    private static func rule(_ operatorId: MutationOperator.Id) -> SarifLog.Rule {
        SarifLog.Rule(
            id: operatorId.rawValue,
            name: operatorId.rawValue,
            shortDescription: SarifLog.Message(text: operatorId.friendlyName),
            fullDescription: SarifLog.Message(text: operatorId.explanation),
            help: SarifLog.Message(text: operatorId.explanation),
            defaultConfiguration: SarifLog.Configuration(level: .warning)
        )
    }

    private func notification(leftOut: Int, of total: Int) -> SarifLog.Notification {
        SarifLog.Notification(
            level: .warning,
            message: SarifLog.Message(
                text: "SwiftMutator left out \(leftOut) of \(total) results, as GitHub code scanning takes at most "
                    + "\(mostResults) from a run: the mutants that survived or timed out come first, then those no "
                    + "test reached."
            )
        )
    }
}

/// The git work tree a folder is in.
enum WorkTree {
    /// Where a project is in a work tree: the tree's root, and the project's folder in it, "" for the root itself.
    struct Place: Equatable {
        let root: String
        let projectFolder: String
    }

    /// Where the project recorded at `projectPath` is in the work tree it's in; nil outside one. When that folder is
    /// gone, as for a results file from another machine or a project moved since, the current folder stands for it,
    /// as `report` is run in the project, and never the nearest folder up from the old path that still has a `.git`.
    static func place(
        of projectPath: String,
        currentFolder: String = FileManager.default.currentDirectoryPath,
        fileExists: (String) -> Bool = FileManager.default.fileExists
    ) -> Place? {
        let recorded = URL(fileURLWithPath: projectPath, isDirectory: true).standardized.path
        let folder = fileExists(recorded)
            ? recorded
            : URL(fileURLWithPath: currentFolder, isDirectory: true).standardized.path
        guard let root = root(containing: folder, fileExists: fileExists) else { return nil }
        let inRoot = RepoRelativePath.of(folder, under: URL(fileURLWithPath: root))
        return Place(root: root, projectFolder: inRoot.hasPrefix("/") ? "" : inRoot)
    }

    /// The nearest folder from `path` up, it included, that holds a `.git`: a folder, or a file in a linked work tree
    /// or a submodule. nil when none does.
    static func root(
        containing path: String,
        fileExists: (String) -> Bool = FileManager.default.fileExists
    ) -> String? {
        var folder = URL(fileURLWithPath: path, isDirectory: true).standardized.path
        while true {
            if fileExists((folder as NSString).appendingPathComponent(".git")) {
                return folder
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { return nil }
            folder = parent
        }
    }
}
