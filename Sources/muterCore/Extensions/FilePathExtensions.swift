import Foundation

extension FilePath {
    /// This path with every symbolic link in it resolved, or the path unchanged if it is relative or
    /// doesn't exist.
    ///
    /// SwiftMutator and the coverage tools can spell the same file differently, so paths from one are
    /// compared with paths from the other in this form. SwiftMutator takes the project's path from
    /// `getcwd()`, which has symbolic links resolved: a project in `/tmp` is at `/private/tmp/…`.
    /// xcodebuild spells it with `/private` dropped, even when handed `/private/tmp/…`, and xccov and
    /// llvm-cov then report every file in the project as `/tmp/…`.
    ///
    /// Foundation's `resolvingSymlinksInPath()` and `standardizingPath` can't undo that: on Darwin they
    /// drop `/private` the same way. A relative path is left alone rather than resolved against whatever
    /// the working directory happens to be.
    var canonicalPath: FilePath {
        guard hasPrefix("/"), let resolved = realpath(self, nil) else {
            return self
        }
        defer { free(resolved) }

        return String(cString: resolved)
    }
}
