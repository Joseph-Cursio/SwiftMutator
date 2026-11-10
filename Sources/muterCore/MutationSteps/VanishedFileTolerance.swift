import Foundation

/// Lets a recursive copy continue past files that disappear after the copy has
/// enumerated them. Every other error, a permission failure included, still
/// stops the copy.
final class VanishedFileTolerance: NSObject, FileManagerDelegate {
    #if os(Linux)
    /// FoundationEssentials makes the delegate `Sendable`. The file manager calls it synchronously on the copying
    /// thread, and the paths are read only once the copy has returned.
    nonisolated(unsafe) private(set) var skippedPaths: [String] = []
    #else
    private(set) var skippedPaths: [String] = []
    #endif

    func fileManager(
        _: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAtPath srcPath: String,
        toPath _: String
    ) -> Bool {
        shouldProceed(afterError: error, copying: srcPath)
    }

    func shouldProceed(afterError error: Error, copying path: String) -> Bool {
        guard Self.isNoSuchFile(error) else {
            return false
        }

        skippedPaths.append(path)
        return true
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return true

        default:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isNoSuchFile(underlying)
            }
            return false
        }
    }
}
