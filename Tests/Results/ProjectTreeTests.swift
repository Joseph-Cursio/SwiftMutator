@testable import muterCore
import XCTest

/// Real folders and a real git: `git init` and `git add`, never a commit.
final class ProjectTreeTests: XCTestCase {
    /// Made for each test, and removed after it.
    private let folder = XCTestCase.unusedTemporaryPath()
    /// The project a test walks: `folder`, unless the test points it elsewhere.
    lazy var project = folder // swiftlint:disable:this test_case_accessibility - tests in its other files use it

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: folder)
        try super.tearDownWithError()
    }

    func test_listsTrackedAndUntrackedFiles_butNotIgnoredOnes() async throws {
        try write([
            ".gitignore": "*.log\nbuild/\n",
            "README.md": "readme",
            "Sources/Sum/Sum.swift": "sum",
            "notes.txt": "untracked",
            "debug.log": "ignored",
            "build/output.txt": "ignored",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", "README.md", "Sources", in: project)

        let tree = await fingerprint()

        XCTAssertEqual(tree.listedBy, .git)
        XCTAssertEqual(tree.files.keys.sorted(), [".gitignore", "README.md", "Sources/Sum/Sum.swift", "notes.txt"])
        XCTAssertEqual(tree.files["Sources/Sum/Sum.swift"], digest(of: "Sources/Sum/Sum.swift"))
        XCTAssertEqual(tree.files["notes.txt"], digest(of: "notes.txt"))
    }

    func test_aTrackedFileThatIsIgnored_isStillListed() async throws {
        try write([
            ".gitignore": "Tests/Fixtures/*.json\n",
            "Tests/Fixtures/tracked.json": "{}",
            "Tests/Fixtures/ignored.json": "{}",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", in: project)
        try git("add", "-f", "Tests/Fixtures/tracked.json", in: project)

        let result = await fingerprint().files.keys.sorted()
        XCTAssertEqual(result, [".gitignore", "Tests/Fixtures/tracked.json"])
    }

    func test_alwaysAddsSwiftAndPackageFiles_evenWhenIgnored() async throws {
        try write([
            ".gitignore": "*\n",
            "Package.swift": "manifest",
            "Package@swift-5.9.swift": "manifest",
            "Package.resolved": "pins",
            ".swift-version": "6.4",
            "Sources/Generated/Generated.swift": "generated",
            "Sub/Package.resolved": "a nested package's pins",
            "Sub/.swift-version": "6.3",
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": "Xcode's pins",
            "App.xcworkspace/xcshareddata/swiftpm/Package.resolved": "Xcode's pins",
            "App.xcodeproj/project.pbxproj": "ignored",
            "notes.txt": "ignored",
        ])
        try git("init", in: project)

        let result = await fingerprint().files.keys.sorted()
        XCTAssertEqual(result, [
            ".swift-version",
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "App.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Package.resolved",
            "Package.swift",
            "Package@swift-5.9.swift",
            "Sources/Generated/Generated.swift",
            "Sub/.swift-version",
        ])
    }

    func test_prunesBuildGitSwiftPMDerivedDataAndXcuserdata_atAnyDepth() async throws {
        try write([
            "Sources/Sum.swift": "kept",
            "Sub/muter-mappings.json": "kept: only the root's is SwiftMutator's",
            ".build/checkouts/Dependency/Sources/Dependency.swift": "pruned",
            "Sub/.build/debug/Generated.swift": "pruned",
            ".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata": "pruned",
            "Sub/.swiftpm/configuration/Package.resolved": "pruned",
            "DerivedData/Build/Intermediates.swift": "pruned",
            "App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/App.xcscheme": "pruned",
            ".DS_Store": "pruned",
            "Sources/.DS_Store": "pruned",
            "muter-mappings.json": "pruned",
            ".swiftmutator-active-mutant": "pruned",
            "muter.xctestrun": "pruned",
            "muter.triage.yml": "pruned",
        ])
        try git("init", in: project)
        try git("add", "-f", ".", in: project)
        let kept = ["Sources/Sum.swift", "Sub/muter-mappings.json"]

        let listed = await fingerprint().files.keys.sorted()
        XCTAssertEqual(listed, kept, "listed by git")
        let walked = await fingerprint { _ in nil }.files.keys.sorted()
        XCTAssertEqual(walked, kept, "walked")
        XCTAssertTrue(ProjectTree.isPruned(".git/config"))
        XCTAssertTrue(ProjectTree.isPruned("Sub/.git/HEAD"))
    }

    // Each xcodebuild worker's test run is SwiftMutator's, as `muter.xctestrun` is, so a plan's copy keeps its
    // fingerprint whatever ran in it. Only at the root, and only as SwiftMutator names one.
    func test_prunesEachXcodebuildWorkersTestRun_atTheRootOnly() async throws {
        try write([
            "Sources/Sum.swift": "kept",
            "muter-worker2.xctestrun": "pruned",
            "muter-worker12.xctestrun": "pruned",
            "muter-worker.xctestrun": "kept: no worker's",
            "Sub/muter-worker2.xctestrun": "kept: only the root's are SwiftMutator's",
        ])
        try git("init", in: project)
        try git("add", "-f", ".", in: project)
        let kept = ["Sources/Sum.swift", "Sub/muter-worker2.xctestrun", "muter-worker.xctestrun"]

        let listed = await fingerprint().files.keys.sorted()
        XCTAssertEqual(listed, kept, "listed by git")
        let walked = await fingerprint { _ in nil }.files.keys.sorted()
        XCTAssertEqual(walked, kept, "walked")
    }

    func test_leavesOutTheExcludedReportAndItsPartialSibling() async throws {
        let folders = try makeDirectoryWithSymbolicLink()
        project = folders.directory
        try write(["Sources/Sum.swift": "sum", "report.txt": "report", "report.partial.txt": "partial report"])
        // Spelled through a symbolic link, as `/tmp` is `/private/tmp`, it is still inside the project.
        let options = Run.Options.make(reportURL: URL(fileURLWithPath: "\(folders.link)/report.txt"))

        let excluded = ProjectTree.reportPaths(options, under: projectURL)
        let tree = await fingerprint(excluding: excluded) { _ in nil }

        XCTAssertEqual(excluded, ["report.txt", "report.partial.txt"])
        XCTAssertEqual(tree.files.keys.sorted(), ["Sources/Sum.swift"])
        XCTAssertEqual(tree.excluded, ["report.partial.txt", "report.txt"])
        XCTAssertEqual(
            ProjectTree.reportPaths(.make(reportURL: URL(fileURLWithPath: "\(project)/out/report")), under: projectURL),
            ["out/report", "out/report.partial"]
        )
        XCTAssertEqual(
            ProjectTree.reportPaths(.make(reportURL: URL(fileURLWithPath: "\(project)_report.txt")), under: projectURL),
            [],
            "a report beside the project, not inside it"
        )
        XCTAssertEqual(ProjectTree.reportPaths(.make(), under: projectURL), [], "no report")
    }

    // The other reports the run saves, and the partial report beside each, as for -o's.
    func test_reportPaths_addTheOtherReports_andTheirPartialSiblings() {
        let reports = [
            ReportRequest(format: .markdown, path: "\(project)/summary.md"),
            ReportRequest(format: .json, path: "\(project)_report.json"),
        ]

        XCTAssertEqual(
            ProjectTree.reportPaths(
                .make(reportURL: URL(fileURLWithPath: "\(project)/report.txt")), under: projectURL, reports: reports
            ),
            ["report.txt", "report.partial.txt", "summary.md", "summary.partial.md"]
        )
        XCTAssertEqual(
            ProjectTree.excludedPaths(.make(), under: projectURL, reports: reports),
            ["summary.md", "summary.partial.md", "muter.conf.yml"]
        )
    }

    // A run leaves its configuration file out too: its settings are in the header, which a resume compares key by key.
    func test_excludedPaths_addTheConfigurationFileTheRunLoads() throws {
        let report = URL(fileURLWithPath: "\(project)/report.txt")
        XCTAssertEqual(
            ProjectTree.excludedPaths(.make(reportURL: report), under: projectURL),
            ["report.txt", "report.partial.txt", "muter.conf.yml"]
        )
        let named = URL(fileURLWithPath: "\(project)/Config/ci.yml")
        XCTAssertEqual(ProjectTree.excludedPaths(.make(configurationURL: named), under: projectURL), ["Config/ci.yml"])
        let configFolder = URL(fileURLWithPath: "\(project)/Config")
        XCTAssertEqual(
            ProjectTree.excludedPaths(.make(configurationURL: configFolder), under: projectURL),
            ["Config/muter.conf.yml"]
        )
        let outside = URL(fileURLWithPath: "\(project)_configuration.yml")
        XCTAssertEqual(ProjectTree.excludedPaths(.make(configurationURL: outside), under: projectURL), [])
    }

    func test_doesNotDescendIntoAnIgnoredNestedCheckout() async throws {
        try write([
            ".gitignore": "/.claude/\n",
            "Sources/Sum.swift": "sum",
            ".claude/worktrees/x/.git": "gitdir: /elsewhere/.git/worktrees/x\n",
            ".claude/worktrees/x/Sources/Sum.swift": "another checkout's",
            ".claude/notes/Draft.swift": "ignored, but Swift",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", "Sources", in: project)

        let result = await fingerprint().files.keys.sorted()
        XCTAssertEqual(result, [
            ".claude/notes/Draft.swift",
            ".gitignore",
            "Sources/Sum.swift",
        ])
    }
}
