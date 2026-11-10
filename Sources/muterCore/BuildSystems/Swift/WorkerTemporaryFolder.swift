import Foundation

/// The temporary folder of a SwiftPM worker's test runs, so that a test that writes a fixed name in the temporary
/// directory doesn't fail another worker's test, which would kill a mutant it doesn't check.
///
/// Two variables name it, set the same for each of the worker's runs, as SwiftPM keys its cache of compiled manifests
/// on the whole environment. `TMPDIR` is what Linux's Foundation, scripts and most other tools go by. On macOS,
/// Foundation's temporary directory comes from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, and doesn't follow it.
/// `DIRHELPER_USER_DIR_SUFFIX` moves that to a folder of this name inside it, and libSystem then sets `TMPDIR` to the
/// same folder. That variable is undocumented, so `WorkerTemporaryFolderVariableTests` checks it. A macOS without it
/// would leave Foundation's temporary directory as shared as it was. It moves `confstr(_CS_DARWIN_USER_CACHE_DIR)` too,
/// so the compiler's own module cache is one for each worker: on a small package, about 0.5 s more for a full build.
/// macOS ignores it for its own programs, such as `/bin/sh` and `swift`, which go by the `TMPDIR` given them.
///
/// The folder is in the temporary directory, not beside the project as a worker's other folders are, for its short
/// path: a Unix domain socket's can't be longer than 104 bytes, which a test that makes one there may be near already.
struct WorkerTemporaryFolder: Equatable {
    /// Short, for the same reason, and the same for every SwiftMutator run of the same folder.
    let name: String
    let path: String

    init(forWorkerIn folder: URL, under temporaryDirectory: URL) {
        name = "sm-" + folder.path.stableHash.prefix(8)
        path = temporaryDirectory.appendingPathComponent(name).path
    }

    /// What a test run in the worker's folder adds to its environment.
    var environment: [String: String] {
        ["TMPDIR": path + "/", "DIRHELPER_USER_DIR_SUFFIX": name]
    }

    /// Removes what the runs in `folder` left in their temporary folder and their cache folder. macOS won't let the
    /// folder it makes for the variable go, or `TemporaryItems` in it, but they are empty, and there is only one for
    /// each worker's folder, which the next run of it uses again.
    static func remove(forWorkerIn folder: URL) {
        let files = FileManager.default
        var places = [files.temporaryDirectory]
        #if os(macOS)
        var cache = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &cache, cache.count) > 0 {
            let cachePath = cache.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            places.append(URL(fileURLWithPath: String(decoding: cachePath, as: UTF8.self)))
        }
        #endif
        for place in places {
            let own = Self(forWorkerIn: folder, under: place).path
            for item in (try? files.contentsOfDirectory(atPath: own)) ?? [] {
                try? files.removeItem(atPath: own + "/" + item)
            }
            try? files.removeItem(atPath: own)
        }
    }
}
