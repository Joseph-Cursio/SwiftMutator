@testable import muterCore
import XCTest

extension FingerprintProjectTreeTests {
    /// Resumes a run of the plan in the project, whose last session recorded `recorded` as the copy it tested.
    /// The plan recorded the project's files as `sources`, and the run builds with `configuration` if given.
    func resumePlan(
        _ recorded: ProjectTree,
        ignoring globs: [String] = [],
        sources: ProjectTree? = nil,
        configuration: MuterConfiguration? = nil
    ) throws {
        let plan = "\(project)/muter-mappings.json"
        if let configuration {
            state.muterConfiguration = configuration
        }
        state.runOptions = .make(
            testPlanURL: URL(fileURLWithPath: plan),
            resumeURL: URL(fileURLWithPath: resultsPath),
            resumeIgnoring: globs
        )
        state.testPlan = LoadedTestPlan(
            path: plan,
            sha256: "91a",
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16",
            scope: nil,
            sources: sources,
            mutatedFiles: nil,
            linkedFiles: nil,
            mutatedPaths: []
        )
        state.resumeState = try ResumeState.make(
            lines: [ResultsHeader.make(project: recorded, usingTestPlan: true), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: resultsPath),
            path: resultsPath
        )
    }

    /// A run of the plan at `path`, which left `mutatedFiles` in the copy, and recorded the project's files as
    /// `sources`.
    func testPlan(at path: String, mutatedFiles: [String: String]?, sources: ProjectTree? = nil) {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: path))
        state.testPlan = LoadedTestPlan(
            path: path,
            sha256: "",
            formatVersion: mutatedFiles == nil ? 0 : TestPlanCoding.formatVersion,
            swiftMutatorVersion: nil,
            scope: nil,
            sources: sources,
            mutatedFiles: mutatedFiles,
            linkedFiles: nil,
            mutatedPaths: []
        )
    }

    /// The paths of each event named `name` sent from now on, until the test ends.
    func recordPaths(of name: RunEvent.Name) -> Locked<[[String]]> {
        let said = Locked<[[String]]>([])
        let subscription = runEvents.observe(name) { event in
            said.change { $0.append(event.object as? [String] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// The paths of each `testPlanCopyEdited` sent from now on, until the test ends.
    func recordCopyEdits() -> Locked<[[String]]> {
        let said = Locked<[[String]]>([])
        let subscription = runEvents.observe(.testPlanCopyEdited) { event in
            said.change { $0.append(event.object as? [String] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// The changes of each `testPlanCopyResolutionChanged` sent from now on, until the test ends.
    func recordResolutionChanges() -> Locked<[[ProjectTree.FileChange]]> {
        let said = Locked<[[ProjectTree.FileChange]]>([])
        let subscription = runEvents.observe(.testPlanCopyResolutionChanged) { event in
            said.change { $0.append(event.object as? [ProjectTree.FileChange] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// Lists `paths` for the project, and records each folder listed.
    func recordListings(_ paths: [String]) -> Locked<[URL]> {
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return paths
        }
        return listed
    }

    func sha256(_ text: String) -> String {
        FileDigest.sha256(of: Data(text.utf8))
    }

    /// Resumes a run whose last session recorded `recorded`.
    func resume(_ recorded: ProjectTree, ignoring globs: [String] = []) throws {
        state.runOptions = .make(resumeURL: URL(fileURLWithPath: resultsPath), resumeIgnoring: globs)
        state.resumeState = try ResumeState.make(
            lines: [ResultsHeader.make(project: recorded), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: resultsPath),
            path: resultsPath
        )
    }

    /// The tree of `files`, each a path relative to the project and its contents, as listed by `listing`, and as a run
    /// that loads the project's own configuration records it.
    func projectTree(of files: [String: String], by listing: ProjectTree.Listing = .git) throws -> ProjectTree {
        let hashes = files.mapValues { FileDigest.sha256(of: Data($0.utf8)) }
        return ProjectTree(
            listedBy: listing,
            files: hashes,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: hashes)
        )
    }

    /// Writes each file, relative to `root`, making its folders.
    func write(_ files: [String: String], in root: String) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(root)/\(path)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }
}
