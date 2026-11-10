import Foundation

#if os(Linux)
/// FoundationEssentials gives `FileManagerDelegate` no default implementations, so the rest of it is spelled out with
/// Darwin's defaults: every item is handled, and any other error stops the operation. Its `copyItem` asks only the URL
/// forms, so a file that vanishes is tolerated there too.
extension VanishedFileTolerance {
    func fileManager(
        _: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAt srcURL: URL,
        to _: URL
    ) -> Bool {
        shouldProceed(afterError: error, copying: srcURL.path)
    }

    func fileManager(_: FileManager, shouldCopyItemAtPath _: String, toPath _: String) -> Bool {
        true
    }

    func fileManager(_: FileManager, shouldCopyItemAt _: URL, to _: URL) -> Bool {
        true
    }

    func fileManager(_: FileManager, shouldMoveItemAtPath _: String, toPath _: String) -> Bool {
        true
    }

    func fileManager(_: FileManager, shouldMoveItemAt _: URL, to _: URL) -> Bool {
        true
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        movingItemAtPath _: String,
        toPath _: String
    ) -> Bool {
        false
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        movingItemAt _: URL,
        to _: URL
    ) -> Bool {
        false
    }

    func fileManager(_: FileManager, shouldLinkItemAtPath _: String, toPath _: String) -> Bool {
        true
    }

    func fileManager(_: FileManager, shouldLinkItemAt _: URL, to _: URL) -> Bool {
        true
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        linkingItemAtPath _: String,
        toPath _: String
    ) -> Bool {
        false
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        linkingItemAt _: URL,
        to _: URL
    ) -> Bool {
        false
    }

    func fileManager(_: FileManager, shouldRemoveItemAtPath _: String) -> Bool {
        true
    }

    func fileManager(_: FileManager, shouldRemoveItemAt _: URL) -> Bool {
        true
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        removingItemAtPath _: String
    ) -> Bool {
        false
    }

    func fileManager(
        _: FileManager,
        shouldProceedAfterError _: Error,
        removingItemAt _: URL
    ) -> Bool {
        false
    }
}
#endif
