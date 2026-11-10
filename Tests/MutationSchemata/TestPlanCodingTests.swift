import ArgumentParser
import Foundation
@testable import muterCore
import XCTest

/// How a test plan is written and read: a file people read, diff and commit, whose bytes depend only on its mutants
/// and on the name of the project's folder.
final class TestPlanCodingTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/path/to/project")
    private let copy = "/path/to/project_mutated"
    private let planPath = "/path/to/project/muter-mappings.json"

    // A file's mutants are kept in a dictionary by code block, so the second plan's are added in the other order.
    func test_twoEqualPlans_areTheSameBytes() throws {
        let first = try plan()
        let second = try plan(addingBlocksInReverse: true)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try TestPlanCoding.encode(first, under: project),
            try TestPlanCoding.encode(second, under: project)
        )
    }

    // The paths are relative and no date, host or executable is recorded, so only the folders' names count.
    func test_theSameProjectInAnotherFolder_isTheSameBytes() throws {
        let here = URL(fileURLWithPath: "/Users/a/Foo")
        let there = URL(fileURLWithPath: "/Volumes/b/Foo")

        XCTAssertEqual(
            try TestPlanCoding.encode(plan(copy: "/Users/a/Foo_mutated"), under: here),
            try TestPlanCoding.encode(plan(copy: "/Volumes/b/Foo_mutated"), under: there)
        )
    }

    // Declared order would put swiftMutatorVersion and mutatedProject before mappings, and a mutant's id before its
    // filePath.
    func test_keysAreSorted() throws {
        let text = try TestPlanCoding.encode(plan(), under: project)

        let keys = [
            "filesToMutate", "formatVersion", "linkedFiles", "mappings", "mutatedFiles", "mutatedProject", "operators",
            "projectCoverage", "sources", "swiftMutatorVersion",
        ]
        assertInOrder(text, keys.map { "\"\($0)\"" })
        let mutant = try String(
            decoding: TestPlanCoding.encoder.encode(mutant(in: "\(copy)/Sources/Sum.swift", line: 1)),
            as: UTF8.self
        )
        assertInOrder(mutant, ["\"filePath\"", "\"id\"", "\"mutationOperatorId\"", "\"position\"", "\"snapshot\""])
    }

    func test_pathsAreRelative_andKeepTheirSlashes() throws {
        let text = try TestPlanCoding.encode(plan(), under: project)

        XCTAssertFalse(text.contains("\\/"))
        XCTAssertFalse(text.contains(copy), text)
        XCTAssertTrue(text.contains("\"mutatedProject\" : \"../project_mutated\""), text)
        XCTAssertTrue(text.contains("\"filePath\" : \"Sources/Sum.swift\""), text)
        XCTAssertTrue(text.contains("\"swiftMutatorVersion\" : \"\(muterCore.version)\""), text)
    }

    func test_eachKeyIsOnALineOfItsOwn_andThePlanEndsInOneNewline() throws {
        let text = try TestPlanCoding.encode(plan(), under: project)

        XCTAssertTrue(text.hasPrefix("{\n  \"filesToMutate\" : ["), text)
        XCTAssertTrue(text.contains("\n  \"formatVersion\" : 2,\n  \"linkedFiles\" : {"), text)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }

    func test_coverageThatWasntGathered_isLeftOut() throws {
        let plan = MuterTestPlan.make(mutatedProjectPath: copy, projectCoverage: -1)

        let text = try TestPlanCoding.encode(plan, under: project)

        XCTAssertFalse(text.contains("projectCoverage"), text)
        XCTAssertEqual(try read(text).projectCoverage, .null)
    }

    // Whatever order --operators named them in, so that the same choice is the same bytes.
    func test_theOperatorsAndFilesThePlanWasChosenBy_areWrittenSorted_andReadBack() throws {
        let plan = MuterTestPlan.make(
            mutatedProjectPath: copy,
            scope: TestPlanScope(operators: [.swapTernary, .ror], filesToMutate: ["Sources/Sum.swift", "Max.swift"])
        )

        let text = try TestPlanCoding.encode(plan, under: project)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(text.utf8))
        XCTAssertEqual(file.operators, ["RelationalOperatorReplacement", "SwapTernary"])
        XCTAssertEqual(file.filesToMutate, ["Sources/Sum.swift", "Max.swift"])
        XCTAssertEqual(
            try read(text).scope,
            TestPlanScope(operators: [.ror, .swapTernary], filesToMutate: ["Sources/Sum.swift", "Max.swift"])
        )
    }

    // A plan from a newer SwiftMutator may name an operator this one doesn't know, as long as it holds no mutant by it.
    func test_anOperatorThisSwiftMutatorDoesntKnow_isLeftOutOfTheScope() throws {
        var text = try TestPlanCoding.encode(MuterTestPlan.make(mutatedProjectPath: copy), under: project)
        text = text.replacingOccurrences(of: "\"SwapTernary\"", with: "\"SwapTernary\", \"SomethingNew\"")

        XCTAssertTrue(text.contains("\"SomethingNew\""), text)
        XCTAssertEqual(
            try read(text).scope?.operators.map(\.rawValue),
            MutationOperatorList.allOperators.map(\.rawValue).sorted()
        )
    }

    // A plan records no syntax, so what it reads back as is compared by the text it would write.
    func test_aPlanReadsBackAsItWasWritten() throws {
        let text = try TestPlanCoding.encode(plan(), under: project)

        let read = try read(text)

        XCTAssertEqual(read.mutatedProjectURL, URL(fileURLWithPath: copy))
        XCTAssertEqual(read.mappings.map(\.filePath), ["\(copy)/Sources/Max.swift", "\(copy)/Sources/Sum.swift"])
        XCTAssertEqual(read.projectCoverage, Coverage(percent: 47))
        XCTAssertEqual(read.formatVersion, TestPlanCoding.formatVersion)
        XCTAssertEqual(read.swiftMutatorVersion, muterCore.version)
        XCTAssertEqual(read.sources, sources)
        XCTAssertEqual(read.mutatedFiles?.keys.sorted(), ["Sources/Max.swift", "Sources/Sum.swift"])
        XCTAssertEqual(read.linkedFiles, ["Sources/Max.swift": "c"])
        XCTAssertEqual(try TestPlanCoding.encode(read, under: project), text)
    }

    // A plan made by a SwiftMutator of this format from before it recorded them reads without them, and isn't checked
    // against the project.
    func test_aPlanWithoutTheProjectsFiles_readsWithout() throws {
        let text = try TestPlanCoding.encode(MuterTestPlan.make(mutatedProjectPath: copy), under: project)

        XCTAssertFalse(text.contains("\"sources\""), text)
        XCTAssertFalse(text.contains("\"mutatedFiles\""), text)
        XCTAssertFalse(text.contains("\"linkedFiles\""), text)
        XCTAssertNil(try read(text).sources)
        XCTAssertNil(try read(text).mutatedFiles)
    }

    // A file outside the copy has no path relative to it, so it keeps its own.
    func test_aPathOutsideTheCopy_staysAbsolute() throws {
        let outside = "/elsewhere/Generated.swift"
        let plan = MuterTestPlan.make(
            mutatedProjectPath: copy,
            mappings: [
                try .make(
                    filePath: outside,
                    (source: "let generated = 1", schemata: [mutant(in: outside, line: 2)])
                ),
            ]
        )

        let text = try TestPlanCoding.encode(plan, under: project)

        XCTAssertTrue(text.contains("\"filePath\" : \"\(outside)\""), text)
        XCTAssertEqual(try read(text).mappings.first?.mutationSchemata.map(\.filePath), [outside])
    }

    // A copy that shares no folder with the project but the root is named by its own path.
    func test_aCopyOnAnotherVolume_isNamedByItsOwnPath() throws {
        let plan = MuterTestPlan.make(mutatedProjectPath: "/Volumes/Scratch/project_mutated")

        let text = try TestPlanCoding.encode(plan, under: project)

        XCTAssertTrue(text.contains("\"mutatedProject\" : \"/Volumes/Scratch/project_mutated\""), text)
        XCTAssertEqual(try read(text).mutatedProjectURL.path, "/Volumes/Scratch/project_mutated")
    }

    // The run's folder is the current directory, whose path can go through a symbolic link, as /private/tmp does for
    // /tmp. Its `..` taken out, the copy's path keeps that form, which the mutants' paths and the lock's are made from.
    func test_theCopysPath_keepsTheFormOfTheProjects() throws {
        // realpath follows /var to /private/var, where `resolvingSymlinksInPath` would take /private away.
        let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let folder = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent(UUID().uuidString)
        let project = folder.appendingPathComponent("project")
        let copy = folder.appendingPathComponent("project_mutated")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = try TestPlanCoding.encode(MuterTestPlan.make(mutatedProjectPath: copy.path), under: project)

        let read = try TestPlanCoding.read(Data(text.utf8), path: planPath, under: project)

        XCTAssertEqual(read.mutatedProjectURL.path, copy.path)
    }

    // Format 1 has format 2's keys, and its copy, named as SwiftMutators from before `.noindex` named it, is read as
    // it was: its lock is `project_mutated.lock`, the file the SwiftMutator that made it locks.
    func test_aPlanInFormat1_readsAsItDid() throws {
        let text = try TestPlanCoding.encode(plan(), under: project)
            .replacingOccurrences(of: "\"formatVersion\" : 2,", with: "\"formatVersion\" : 1,")

        let read = try read(text)

        XCTAssertTrue(text.contains("\"mutatedProject\" : \"../project_mutated\""), text)
        XCTAssertEqual(read.formatVersion, 1)
        XCTAssertEqual(read.mutatedProjectURL, URL(fileURLWithPath: copy))
        XCTAssertEqual(read.mappings.map(\.filePath), ["\(copy)/Sources/Max.swift", "\(copy)/Sources/Sum.swift"])
        XCTAssertEqual(MutatedProjectLock.path(for: read.mutatedProjectURL), "\(copy).lock")
    }

    // A plan written by a SwiftMutator from before format versions: one line, absolute paths, -1 for coverage that
    // wasn't gathered, and, from before the path hash, a mutant without an id.
    func test_aPlanInFormat0_readsWithItsAbsolutePaths() throws {
        let line = """
        {"mutatedProjectPath":"\\/old\\/project_mutated","projectCoverage":-1,"mappings":[{"filePath":\
        "\\/old\\/project_mutated\\/Sources\\/Sum.swift","mappings":[{"filePath":\
        "\\/old\\/project_mutated\\/Sources\\/Sum.swift","mutationOperatorId":"RelationalOperatorReplacement",\
        "position":{"utf8Offset":105,"line":1,"column":5},\
        "snapshot":{"before":"a > b","after":"a < b","description":"changed > to <"}}]}]}
        """

        let read = try read(line)

        XCTAssertEqual(read.formatVersion, 0)
        XCTAssertNil(read.swiftMutatorVersion)
        XCTAssertEqual(read.mutatedProjectURL, URL(fileURLWithPath: "/old/project_mutated"))
        XCTAssertEqual(read.projectCoverage, .null)
        let schema = try XCTUnwrap(read.mappings.first?.mutationSchemata.first)
        XCTAssertEqual(schema.filePath, "/old/project_mutated/Sources/Sum.swift")
        XCTAssertEqual(schema.id, "Sum_RelationalOperatorReplacement_1_5_105")
        XCTAssertNil(read.scope)
        XCTAssertNil(read.sources)
        XCTAssertNil(read.mutatedFiles)
    }

    func test_aNewerFormat_isRefused_andExitsWith7() throws {
        let text = """
        {"formatVersion": 3, "somethingNew": true}
        """

        XCTAssertThrowsError(try read(text)) { error in
            let refused = error as? TestPlanRefused
            XCTAssertEqual(refused, TestPlanRefused(path: planPath, reason: .newerFormat(found: 3)))
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .testPlanRefused)
            XCTAssertEqual(
                "\(error)",
                "SwiftMutator won't test the plan '\(planPath)': it is in test plan format 3, which only a newer "
                    + "SwiftMutator can read. Test it with the SwiftMutator that made it, or make it again with "
                    + "`swift-mutator mutate-without-running`. Nothing was tested."
            )
        }
    }

    /// The project's files, as `FingerprintProjectTree` records them, by their paths relative to the project.
    private var sources: ProjectTree {
        let files = ["Sources/Max.swift": "c", "Sources/Sum.swift": "d", "Tests/SumTests.swift": "e"]
        return ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
    }

    private func read(_ text: String) throws -> MuterTestPlan {
        try TestPlanCoding.read(Data(text.utf8), path: planPath, under: project)
    }

    private func plan(copy: String? = nil, addingBlocksInReverse: Bool = false) throws -> MuterTestPlan {
        let copy = copy ?? self.copy
        var sum = SchemataMutationMapping(filePath: "\(copy)/Sources/Sum.swift")
        // Each block's leading spaces put its first statement at an offset of its own.
        for number in addingBlocksInReverse ? Array((1 ... 8).reversed()) : Array(1 ... 8) {
            let block = try sourceCode(String(repeating: " ", count: number) + "let block\(number) = \(number)")
            try sum.add(block.statements, mutant(in: sum.filePath, line: number, copy: copy))
        }
        return .make(
            mutatedProjectPath: copy,
            projectCoverage: 47,
            sources: sources,
            mutatedFiles: ["Sources/Max.swift": String(repeating: "a", count: 64), "Sources/Sum.swift": "b"],
            linkedFiles: ["Sources/Max.swift": "c"],
            mappings: [
                try .make(
                    filePath: "\(copy)/Sources/Max.swift",
                    (
                        source: "let max = 1",
                        schemata: [mutant(in: "\(copy)/Sources/Max.swift", line: 3, copy: copy)]
                    )
                ),
                sum,
            ]
        )
    }

    private func mutant(in filePath: String, line: Int, copy: String? = nil) throws -> MutationSchema {
        try .make(
            filePath: filePath,
            mutationOperatorId: .ror,
            position: MutationPosition(utf8Offset: line * 100 + 5, line: line, column: 5),
            snapshot: .make(before: "a > b", after: "a < b", description: "changed > to <"),
            under: URL(fileURLWithPath: copy ?? self.copy)
        )
    }

    private func assertInOrder(
        _ text: String,
        _ keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offsets = keys.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(offsets.contains(nil), "Missing one of \(keys) in \(text)", file: file, line: line)
        let found = offsets.compactMap(\.self)
        XCTAssertEqual(found, found.sorted(), "\(keys) aren't in this order in \(text)", file: file, line: line)
    }
}
