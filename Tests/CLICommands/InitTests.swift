@testable import muterCore
import XCTest

final class InitTests: MuterTestCase {
    private var directory: String!
    private lazy var sut = Init(directory: directory)

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
    }

    func test_createsAConfigurationFileNamedMuterConfYmlWithPlaceholderValuesInASpecifiedDirectory() async throws {
        try await sut.run()
        guard let contents = FileManager.default.contents(atPath: "\(directory!)/muter.conf.yml"),
              let _ = try? MuterConfiguration(from: contents)
        else {
            XCTFail("Expected a valid configuration file to be written")
            return
        }
    }

    // No run observes init, so nothing it sent was ever said: it printed nothing at all.
    func test_saysWhereItCreatedTheConfigurationFile() async throws {
        try await sut.run()

        XCTAssertTrue(printer.linesPassed.contains { $0.contains("You are running version") }, "\(printer.linesPassed)")
        XCTAssertEqual(printer.linesPassed.last, "💾 Configuration file created at: \(directory!)/muter.conf.yml")
    }

    // A folder it can't write to: it says so, rather than that it created the file.
    func test_whenTheFileCantBeWritten_itSaysSo_andThrows() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        addTeardownBlock { [directory] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory!)
        }

        do {
            try await sut.run()
            XCTFail("init said it created \(directory!)/muter.conf.yml")
        } catch {
            XCTAssertEqual("\(error)", "SwiftMutator could not write \(directory!)/muter.conf.yml.")
        }
        XCTAssertFalse(printer.linesPassed.contains { $0.contains("Configuration file created") })
    }
}
