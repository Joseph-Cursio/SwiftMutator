import XCTest

final class FileManagerCanaryTests: XCTestCase {
    func test_namesTemporaryFilesPredictably() {
        let volumeRoot = URL(fileURLWithPath: "/")
        do {
            let temporaryDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: volumeRoot,
                create: true
            )

            #if os(Linux)
            XCTAssertTrue(temporaryDirectory.absoluteString.contains("/tmp/TemporaryItems/"))
            #else
            // Under SwiftMutator, as in `make mutation-test`, a worker's runs get their own temporary folder in `T`,
            // named by `DIRHELPER_USER_DIR_SUFFIX` (WorkerTemporaryFolder).
            let suffix = ProcessInfo.processInfo.environment["DIRHELPER_USER_DIR_SUFFIX"] ?? ""
            let workerFolder = suffix.isEmpty ? "" : suffix + "/"
            XCTAssertTrue(temporaryDirectory.absoluteString.contains("/var/folders"))
            XCTAssertTrue(
                temporaryDirectory.absoluteString.contains("/T/\(workerFolder)TemporaryItems/"),
                temporaryDirectory.absoluteString
            )
            #endif
        } catch {
            XCTFail("Expected no errors, but got \(error)")
        }
    }
}
