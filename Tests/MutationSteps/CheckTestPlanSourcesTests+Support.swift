import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension CheckTestPlanSourcesTests {
    /// A loaded plan made from the project's `recorded` files, with mutants in `paths`, relative to the copy.
    func plan(mutating paths: [String]) {
        plan(mutating: paths, recorded: recorded)
    }

    /// A loaded plan made from `recorded`, the project's files when it was made, or by a SwiftMutator that didn't
    /// record them, with mutants in `paths`, relative to the copy, of which the run tests those in `tested`, as
    /// `--mutant` narrows them, or every one. Each of `links` is a symbolic link in the project, to the path it names,
    /// whose file held the text it names when the plan was made.
    func plan(
        mutating paths: [String],
        recorded: [String: String]?,
        tested: [String]? = nil,
        links: [String: (destination: String, text: String)] = [:]
    ) {
        let linked = links.mapValues { ProjectTree.linkPrefix + FileDigest.sha256(of: Data($0.destination.utf8)) }
        let files = recorded.map { $0.mapValues { FileDigest.sha256(of: Data($0.utf8)) }.merging(linked) { $1 } }
        state.testPlan = LoadedTestPlan(
            path: planPath,
            sha256: "",
            formatVersion: files == nil ? 0 : TestPlanCoding.formatVersion,
            swiftMutatorVersion: files == nil ? nil : muterCore.version,
            scope: nil,
            sources: files.map { listed in
                ProjectTree(
                    listedBy: .git,
                    files: listed,
                    excluded: ["muter.conf.yml"],
                    treeSHA256: ProjectTree.treeHash(of: listed)
                )
            },
            mutatedFiles: nil,
            linkedFiles: links.isEmpty ? nil : links.mapValues { FileDigest.sha256(of: Data($0.text.utf8)) },
            mutatedPaths: Set(paths)
        )
        state.mutationMapping = (tested ?? paths).map { SchemataMutationMapping(filePath: "\(copyPath)/\($0)") }
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

    static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }
}
