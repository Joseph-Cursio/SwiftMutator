import Foundation

extension DirectTestRun {
    /// Ends the name of the link to the helper, beside a worker's folder.
    static let helperLinkSuffix = ".swiftpm-testing-helper"

    /// The link `script(in:)` starts the helpers through for a worker's folder, the mutated project or a clone:
    /// `<stem>.swiftpm-testing-helper`, beside it, named after the folder without `.noindex` as the active-mutant file
    /// is, so an older SwiftMutator's link and its tests' domain have the names this one gives them. A process with no
    /// bundle identifier, as the helper is, keeps its `UserDefaults` in a domain named after its executable's file,
    /// which a link sets but a changed `argv[0]` doesn't. So each worker's tests get a domain of their own, where every
    /// worker once shared the helper's, and with it every other `swift test` run on the Mac: tests that wrote a fixed
    /// key there could fail another worker's tests, and kill mutants they don't check (#92).
    static func helperLink(forWorkerIn folder: URL) -> URL {
        MutatedProjectNames.file(helperLinkSuffix, beside: folder)
    }

    /// The `UserDefaults` domain of the tests run directly in `folder`: the name of its helper link.
    static func defaultsDomain(forWorkerIn folder: URL) -> String {
        helperLink(forWorkerIn: folder).lastPathComponent
    }

    /// Removes the helper link beside `folder` and its tests' `UserDefaults`, once SwiftMutator is done with the
    /// folder.
    static func removeOwnDefaults(forWorkerIn folder: URL) {
        let link = helperLink(forWorkerIn: folder)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try? FileManager.default.removeItem(at: link)
        removeDefaultsDomain(defaultsDomain(forWorkerIn: folder))
    }

    /// Removes `domain`, one of SwiftMutator's own, and the file in the user's preferences that held it. `defaults`
    /// empties it, as SwiftMutator itself would write its copy back to disk when it exits, and the file left empty then
    /// goes. Waits at most `timeLimit` seconds for `defaults`, which leaves the domain in place if it takes longer.
    static func removeDefaultsDomain(_ domain: String, timeLimit: TimeInterval = 5) {
        #if os(macOS)
        let delete = Foundation.Process()
        delete.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        delete.arguments = ["delete", domain]
        delete.standardOutput = FileHandle.nullDevice
        delete.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        delete.terminationHandler = { _ in exited.signal() }
        guard (try? delete.run()) != nil, exited.wait(timeout: .now() + timeLimit) == .success else { return }
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(at: file)
        #endif
    }
}
