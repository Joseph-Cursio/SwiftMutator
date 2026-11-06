@testable import muterCore
import XCTest

final class MutatedProjectNamesTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/code/x")
    private var copy: URL { MutatedProjectNames.copy(of: project, forOneMutant: false) }
    private var oneMutantCopy: URL { MutatedProjectNames.copy(of: project, forOneMutant: true) }

    // Spotlight skips a folder whose own name ends in `.noindex`, and only by that name: it would index
    // `x_mutated.noindex_worker1`, or `x_mutated.noindex.DerivedData`. Each name still starts with the copy's, so the
    // README's `*_mutated*` keeps them out of git.
    func test_everyFolderBesideTheProject_endsInNoindex_andMatchesTheIgnorePattern() {
        let folders = [
            copy,
            MutatedProjectNames.clone(2, of: copy),
            MutatedProjectNames.derivedData(ofWorker: 0, in: copy),
            MutatedProjectNames.derivedData(ofWorker: 3, in: copy),
        ]

        XCTAssertEqual(folders.map(\.path), [
            "/code/x_mutated.noindex",
            "/code/x_mutated_worker2.noindex",
            "/code/x_mutated.DerivedData.noindex",
            "/code/x_mutated_worker3.DerivedData.noindex",
        ])
        for folder in folders {
            XCTAssertEqual(folder.pathExtension, "noindex", folder.path)
            XCTAssertEqual(fnmatch("*_mutated*", folder.lastPathComponent, 0), 0, folder.path)
        }
        XCTAssertEqual(oneMutantCopy.path, "/code/x_mutant.noindex")
        XCTAssertEqual(MutatedProjectNames.clone(1, of: oneMutantCopy).path, "/code/x_mutant_worker1.noindex")
        XCTAssertEqual(fnmatch("*_mutant*", oneMutantCopy.lastPathComponent, 0), 0)
    }

    // The README's advice for a package inside a larger git repository names the patterns to ignore. Between them they
    // must match every folder and file SwiftMutator makes beside the project, a run of one mutant's too, whose names
    // `*_mutated*` doesn't match.
    func test_theIgnorePatternsTheReadmeAdvises_matchEveryNameBesideTheProject() throws {
        let readme = try String(
            contentsOfFile: URL(fileURLWithPath: rootTestDirectory).deletingLastPathComponent()
                .appendingPathComponent("README.md").path,
            encoding: .utf8
        )
        let advice = try XCTUnwrap(
            readme.components(separatedBy: "\n- ").first { $0.contains("inside a larger git repository, ignore") },
            "the README no longer advises what to ignore"
        )
        let patterns = try NSRegularExpression(pattern: "`(\\*[^`*]+\\*)`")
            .matches(in: advice, range: NSRange(advice.startIndex..., in: advice))
            .compactMap { Range($0.range(at: 1), in: advice).map { String(advice[$0]) } }
        XCTAssertEqual(Set(patterns), ["*_mutated*", "*_mutant*"], advice)
        let names = [copy, oneMutantCopy].flatMap { copy in
            [
                copy,
                MutatedProjectNames.clone(2, of: copy),
                MutatedProjectNames.derivedData(ofWorker: 0, in: copy),
                MutatedProjectNames.derivedData(ofWorker: 3, in: copy),
                MutationTestingDelegate.activeMutantFile(forWorkerIn: copy),
                DirectTestRun.helperLink(forWorkerIn: copy),
                URL(fileURLWithPath: MutatedProjectNames.lockFile(of: copy)),
            ].map(\.lastPathComponent)
        }
        for name in names {
            XCTAssertTrue(patterns.contains { fnmatch($0, name, 0) == 0 }, "\(name) matches none of \(patterns)")
        }
        XCTAssertNotEqual(fnmatch("*_mutated*", oneMutantCopy.lastPathComponent, 0), 0)
    }

    func test_aFoldersStem_isItsNameWithoutNoindex_whenItIsACopyOrAClone() {
        XCTAssertEqual(MutatedProjectNames.stem("x_mutated.noindex"), "x_mutated")
        XCTAssertEqual(MutatedProjectNames.stem("x_mutant.noindex"), "x_mutant")
        XCTAssertEqual(MutatedProjectNames.stem("x_mutated_worker12.noindex"), "x_mutated_worker12")
        // As an older SwiftMutator named its copy, which a test plan it made names.
        XCTAssertEqual(MutatedProjectNames.stem("x_mutated"), "x_mutated")
        XCTAssertEqual(MutatedProjectNames.stem("x_mutated_worker2"), "x_mutated_worker2")
    }

    // A test plan's copy can be any folder. One that only happens to end in `.noindex` keeps its whole name, so its
    // lock isn't a file of the user's.
    func test_anotherFolderEndingInNoindex_isItsOwnStem() {
        XCTAssertEqual(MutatedProjectNames.stem("Scratch.noindex"), "Scratch.noindex")
        XCTAssertEqual(MutatedProjectNames.stem("x_worker.noindex"), "x_worker.noindex")
        XCTAssertEqual(MutatedProjectNames.stem("x_mutated.DerivedData.noindex"), "x_mutated.DerivedData.noindex")
        XCTAssertEqual(
            MutatedProjectNames.lockFile(of: URL(fileURLWithPath: "/scratch/Scratch.noindex")),
            "/scratch/Scratch.noindex.lock"
        )
    }

    // So an older SwiftMutator, running in `x_mutated`, and this one, in `x_mutated.noindex`, exclude each other.
    func test_theLockFile_isNamedAfterTheStem() {
        XCTAssertEqual(MutatedProjectNames.lockFile(of: copy), "/code/x_mutated.lock")
        let older = URL(fileURLWithPath: "/code/x_mutated")
        XCTAssertEqual(MutatedProjectNames.lockFile(of: older), "/code/x_mutated.lock")
        XCTAssertEqual(MutatedProjectNames.lockFile(of: oneMutantCopy), "/code/x_mutant.lock")
        XCTAssertEqual(MutatedProjectLock.path(for: copy), "/code/x_mutated.lock")
    }

    // The names older SwiftMutators gave them, so cleanup finds one an older run left, and the README's examples hold.
    func test_theFilesBesideAClone_keepTheNamesOlderSwiftMutatorsGaveThem() {
        let clone = MutatedProjectNames.clone(2, of: copy)

        XCTAssertEqual(
            MutationTestingDelegate.activeMutantFile(forWorkerIn: clone).path,
            "/code/x_mutated_worker2.active-mutant"
        )
        XCTAssertEqual(
            DirectTestRun.helperLink(forWorkerIn: clone).path,
            "/code/x_mutated_worker2.swiftpm-testing-helper"
        )
        XCTAssertEqual(DirectTestRun.defaultsDomain(forWorkerIn: clone), "x_mutated_worker2.swiftpm-testing-helper")
        XCTAssertEqual(
            MutationTestingDelegate.activeMutantFile(forWorkerIn: copy).path,
            "/code/x_mutated.active-mutant"
        )
    }

    func test_leftovers_areTheCopysFoldersUnderEitherName_andTheFilesBesideThem() {
        let leftovers = [
            "x_mutated", // an older SwiftMutator's copy
            "x_mutated_worker1", "x_mutated_worker1.noindex",
            "x_mutated.DerivedData", "x_mutated.DerivedData.noindex",
            "x_mutated_worker4.DerivedData", "x_mutated_worker4.DerivedData.noindex",
            "x_mutated.active-mutant", "x_mutated_worker1.active-mutant",
            "x_mutated.swiftpm-testing-helper", "x_mutated_worker3.swiftpm-testing-helper",
        ]
        let kept = [
            "x", "x_mutated.lock", "x_muter_logs",
            "x_mutated_worker.noindex", "x_mutated_workerfoo.noindex", "x_mutated_worker2.noindex.txt",
            "y_mutated.noindex", "y_mutated_worker1.noindex", "y_mutated.DerivedData.noindex",
            "x_mutated.active-mutant.noindex", "x_mutated.noindex.DerivedData", "x_mutated.noindex.active-mutant",
            "x_mutated.lock.noindex", "x_mutant.noindex", "x_mutant", "x_mutated_worker1.DerivedData.txt",
        ]

        for name in leftovers {
            XCTAssertTrue(MutatedProjectNames.isLeftover(name, of: "x_mutated"), name)
        }
        for name in kept {
            XCTAssertFalse(MutatedProjectNames.isLeftover(name, of: "x_mutated"), name)
        }
    }

    func test_activationFolders_areBesideTheirWorkersFolders_andAreLeftovers() {
        let copy = URL(fileURLWithPath: "/runs/p_mutated.noindex")
        let clone = URL(fileURLWithPath: "/runs/p_mutated_worker2.noindex")

        XCTAssertEqual(MutatedProjectNames.activationFolder(of: copy).path, "/runs/p_mutated.Activation.noindex")
        XCTAssertEqual(
            MutatedProjectNames.activationFolder(of: clone).path,
            "/runs/p_mutated_worker2.Activation.noindex"
        )
        XCTAssertTrue(MutatedProjectNames.isLeftover("p_mutated.Activation.noindex", of: "p_mutated"))
        XCTAssertTrue(MutatedProjectNames.isLeftover("p_mutated_worker2.Activation.noindex", of: "p_mutated"))
        XCTAssertFalse(MutatedProjectNames.isLeftover("other.Activation.noindex", of: "p_mutated"))
    }
}
