import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Source Code

func sourceCode(fromFileAt path: String) -> SourceCodeInfo? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let source = String(data: data, encoding: .utf8)
    else {
        return nil
    }

    let code = Parser.parse(source: source)
    return SourceCodeInfo(
        path: path,
        code: code
    )
}

// MARK: - Logging Directory

/// Creates `<project>_muter_logs/<timestamp>` next to the project, the same way
/// the mutated copy is `<project>_mutated`. Never inside the project: a log
/// folder there is copied into the next run's mutated project and shows up as
/// untracked files in the user's repository.
///
/// The timestamp is to the minute. A run that starts in a minute that already
/// has a folder, such as a session resumed at once, gets `<timestamp> (2)`, then
/// `(3)` and so on: sharing one, its kept logs would replace the earlier run's.
/// Throws if either folder can't be made, which ends the run before any step.
func createLoggingDirectory(
    forProjectAt projectDirectory: String,
    fileManager: FileSystemManager = FileManager.default,
    locale: Locale = .autoupdatingCurrent,
    timestamp: () -> Date = Date.init
) throws -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"

    // String path operations, not URL(fileURLWithPath:), which would resolve a
    // relative or `~` path against the current directory.
    let project = projectDirectory as NSString
    let logsRoot = (project.deletingLastPathComponent as NSString)
        .appendingPathComponent(project.lastPathComponent + "_muter_logs")
    do {
        try fileManager.createDirectory(atPath: logsRoot, withIntermediateDirectories: true, attributes: nil)
        return try claimFolder(named: formatter.string(from: timestamp()), in: logsRoot, fileManager: fileManager)
    } catch {
        throw MuterError.literal(reason: "SwiftMutator could not create its log folder in \(logsRoot): \(error)")
    }
}

/// Makes `name` in `folder`, or the first of `name (2)`, `name (3)` and so on
/// that isn't there. Making a folder fails if it is there, so two runs that
/// start at once never claim the same one.
private func claimFolder(named name: String, in folder: String, fileManager: FileSystemManager) throws -> String {
    var number = 1
    while true {
        let claimed = (folder as NSString).appendingPathComponent(number == 1 ? name : "\(name) (\(number))")
        do {
            try fileManager.createDirectory(atPath: claimed, withIntermediateDirectories: false, attributes: nil)
            return claimed
        } catch {
            guard fileManager.fileExists(atPath: claimed) else { throw error }
        }
        number += 1
    }
}
