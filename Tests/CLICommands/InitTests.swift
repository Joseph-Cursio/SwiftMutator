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
}
