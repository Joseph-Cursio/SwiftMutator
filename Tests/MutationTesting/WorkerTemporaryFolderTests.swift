import Foundation
@testable import muterCore
import XCTest

final class WorkerTemporaryFolderTests: MuterTestCase {
    private let temporary = URL(fileURLWithPath: "/private/var/T")
    private let project = URL(fileURLWithPath: "/runs/p_mutated.noindex")
    private let clone = URL(fileURLWithPath: "/runs/p_mutated_worker1.noindex")

    func test_eachWorkerHasOne_namedTheSameForEveryRun() {
        let first = WorkerTemporaryFolder(forWorkerIn: project, under: temporary)

        XCTAssertEqual(first, WorkerTemporaryFolder(forWorkerIn: project, under: temporary))
        XCTAssertNotEqual(first, WorkerTemporaryFolder(forWorkerIn: clone, under: temporary))
    }

    func test_itsEnvironment_namesTheFolder() {
        let folder = WorkerTemporaryFolder(forWorkerIn: project, under: temporary)

        XCTAssertEqual(folder.path, temporary.path + "/" + folder.name)
        XCTAssertEqual(
            folder.environment,
            ["TMPDIR": folder.path + "/", "DIRHELPER_USER_DIR_SUFFIX": folder.name]
        )
    }

    // A Unix domain socket's path can't be longer than 104 bytes, so it adds as little as it can to the directory's.
    func test_itsNameIsShort() {
        XCTAssertLessThanOrEqual(WorkerTemporaryFolder(forWorkerIn: project, under: temporary).name.count, 11)
    }

    // A test that writes a fixed name in the temporary directory would otherwise fail another worker's test. SwiftPM
    // keys its manifest cache on the whole environment, so a baseline and a mutant's run in a folder get the same one.
    func test_eachSwiftPMWorker_hasATemporaryFolderOfItsOwn_forEveryRun() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let schemata = try MutationSchema.make()
        process.environment = [:]
        let made = Locked<[String]>([])
        current.makeFolder = { path in made.change { $0.append(path) } }
        var seen: Set<String> = []

        for folder in ["/runs/p_mutated", "/runs/p_mutated_worker1"] {
            let worker = URL(fileURLWithPath: folder)
            let own = WorkerTemporaryFolder(forWorkerIn: worker, under: FileManager.default.temporaryDirectory)
            for ranMutant in [MutationSchema.null, schemata] {
                let testProcess = try MutationTestingDelegate().testProcess(
                    with: configuration,
                    schemata: ranMutant,
                    and: FileHandle(fileDescriptor: 0),
                    workingDirectory: worker
                )

                XCTAssertEqual(testProcess.environment?["TMPDIR"], own.path + "/", folder)
                XCTAssertEqual(testProcess.environment?["DIRHELPER_USER_DIR_SUFFIX"], own.name, folder)
                XCTAssertEqual(made.value.last, own.path, "`swift` stops if TMPDIR names no folder")
            }
            seen.insert(own.path)
        }
        XCTAssertEqual(seen.count, 2)
    }

    // An xcodebuild worker tests on a simulator of its own, with its own temporary directory.
    func test_anotherBuildSystem_keepsTheTemporaryDirectory() throws {
        process.environment = ["TMPDIR": "/inherited/"]
        let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])

        let testProcess = try MutationTestingDelegate().testProcess(
            with: configuration,
            schemata: try MutationSchema.make(),
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(testProcess.environment?["TMPDIR"], "/inherited/")
        XCTAssertNil(testProcess.environment?["DIRHELPER_USER_DIR_SUFFIX"])
    }

    func test_remove_removesWhatTheRunsLeft() throws {
        let worker = URL(fileURLWithPath: "/runs/removed-\(UUID().uuidString)")
        let folder = WorkerTemporaryFolder(forWorkerIn: worker, under: FileManager.default.temporaryDirectory)
        try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
        let left = folder.path + "/fixture"
        XCTAssertTrue(FileManager.default.createFile(atPath: left, contents: Data()))

        WorkerTemporaryFolder.remove(forWorkerIn: worker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: left))
    }
}
