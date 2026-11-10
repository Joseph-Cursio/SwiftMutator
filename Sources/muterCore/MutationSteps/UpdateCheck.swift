#if os(Linux)
import FoundationNetworking
#endif
import Foundation
import Version

private let url = "https://api.github.com/repos/Joseph-Cursio/SwiftMutator/releases?per_page=1"

private enum UpdateCheckError: Error {
    case parsingError
}

struct MuterVersion: Decodable {
    let number: String

    private enum CodingKeys: String, CodingKey {
        case number = "tag_name"
    }
}

struct UpdateCheck: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.server)
    private var server: Server

    private let currentVersion: Version

    init(currentVersion: Version? = Version(tolerant: version)) {
        self.currentVersion = currentVersion ?? .null
    }

    func run(
        with _: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        guard let releaseURL = URL(string: url) else {
            return []
        }

        events.send(.updateCheckStarted)

        do {
            let (data, _) = try await server.data(from: releaseURL)

            guard let newVersion = try? muterLatestVersion(data),
                  currentVersion < newVersion
            else {
                events.send(.updateCheckFinished(newVersion: nil))
                return []
            }

            let latestVersion = newVersion.description

            events.send(.updateCheckFinished(newVersion: latestVersion))

            return [
                .newVersionAvaiable(latestVersion)
            ]
        } catch {
            // A request cancelled because the run is stopping says nothing about versions.
            try Task.checkCancellation()
            events.send(.updateCheckFinished(newVersion: nil))
            return []
        }
    }

    private func muterLatestVersion(_ data: Data) throws -> Version {
        guard let release = try? JSONDecoder().decode([MuterVersion].self, from: data),
              let muterVersion = release.first,
              let latestVersion = Version(tolerant: muterVersion.number)
        else {
            throw UpdateCheckError.parsingError
        }

        return latestVersion
    }
}
