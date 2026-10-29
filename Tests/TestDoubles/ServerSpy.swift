#if os(Linux)
import FoundationNetworking
#endif
import Foundation
@testable import muterCore

// A test sets it up, then the code under test uses it from one task at a time, so it needs no lock.
final class ServerSpy: Server, @unchecked Sendable {
    private(set) var urlPassed: URL?

    var dataToBeReturned: Data = .init()
    var urlResponseToBeReturned: URLResponse = .init(
        url: URL(fileURLWithPath: ""),
        mimeType: nil,
        expectedContentLength: 0,
        textEncodingName: nil
    )
    var errorToBeThrown: Error?
    /// Called as each request is under way, before it returns or throws, so a test can cancel the check meanwhile.
    var whileFetching: (() -> Void)?

    func data(from url: URL) async throws -> (Data, URLResponse) {
        urlPassed = url
        whileFetching?()

        if let errorToBeThrown {
            throw errorToBeThrown
        }

        return (dataToBeReturned, urlResponseToBeReturned)
    }
}
