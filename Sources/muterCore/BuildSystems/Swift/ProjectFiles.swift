import Foundation

/// Each file and folder in a project, with its size and when it last changed, so that two readings show whether what
/// ran between them wrote anything there. A folder's time changes when something is made or removed in it, so a test
/// that writes a fixture and removes it shows too.
struct ProjectFiles: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let mode: UInt32
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    let entries: [String: Entry]

    /// `project`'s files, not following links, or nil if they can't be listed.
    static func read(in project: URL) -> Self? {
        #if os(macOS)
        guard let enumerator = FileManager.default.enumerator(atPath: project.path) else { return nil }
        var readEntries: [String: Entry] = [:]
        readEntries[""] = entry(atPath: project.path)
        while let name = enumerator.nextObject() as? String {
            readEntries[name] = entry(atPath: project.path + "/" + name)
        }
        return Self(entries: readEntries)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func entry(atPath path: String) -> Entry? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Entry(
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size),
            seconds: status.st_mtimespec.tv_sec,
            nanoseconds: status.st_mtimespec.tv_nsec
        )
    }
    #endif

    /// The first, by name, of the paths whose entry differs in `later`, or else "" for the project's own folder, which
    /// differs alone when something was made and removed at its top; nil if none does.
    func firstChange(in later: Self) -> String? {
        let changed = Set(entries.keys).union(later.entries.keys).filter { entries[$0] != later.entries[$0] }
        return changed.filter { !$0.isEmpty }.min() ?? changed.first
    }
}
