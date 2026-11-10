#if os(Linux)
import FoundationNetworking
#endif
import Foundation

protocol Server: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

#if os(Linux)
extension URLSession: Server {
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            dataTask(with: url) { data, urlResponse, error in
                if let data, let urlResponse {
                    continuation.resume(returning: (data, urlResponse))
                } else if let error {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }
}
#else
extension URLSession: Server {}
#endif
