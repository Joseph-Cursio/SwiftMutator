import Foundation

extension XcodeTargetSources {
    /// Adds to `listing` the Swift files in the folders synced with the groups of the target `id` of `file`, but the
    /// ones its exceptions take out; `cantPlace` names a folder SwiftMutator can't place.
    static func addFoldersSynced(
        withGroupsOf id: String,
        of file: ProjectFile,
        to listing: inout Listing,
        cantPlace: (String) -> Failure
    ) -> Failure? {
        let target = file.objects[id] ?? [:]
        for group in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let folder = file.location(of: group) else { return cantPlace("a folder synced with a group") }
            let exceptions = (file.objects[group]?["exceptions"] as? [String] ?? []).compactMap { file.objects[$0] }
            // A kind of exception SwiftMutator doesn't know may add files: every file in the folder counts then.
            let known = exceptions.allSatisfy { exception in
                exception["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet"
            }
            let excluded = exceptions
                .filter { known && $0["target"] as? String == id }
                .flatMap { $0["membershipExceptions"] as? [String] ?? [] }
            let resolved = folder.canonicalPath
            // A file counts unless every target that owns the folder takes it out.
            listing.folders[resolved] = listing.folders[resolved].map { $0.intersection(excluded) } ?? Set(excluded)
        }
        return nil
    }

    /// The files that the exceptions of the synced folder `group` of `file` add to targets under test that don't own
    /// it, by those targets' IDs, as an app extension's files often are, in a folder no target owns; nil for a kind of
    /// exception SwiftMutator doesn't know, with no target, whose folder counts whole. An exception for a target that
    /// owns the folder takes files out of it instead (`add(target:of:named:to:)`). An entry that is a folder adds every
    /// file in it.
    static func exceptionsAdding(
        from group: String,
        of file: ProjectFile,
        named project: String
    ) -> Result<[String?: Listing], Failure> {
        let owners = Set(file.objects.compactMap { id, object in
            (object["fileSystemSynchronizedGroups"] as? [String])?.contains(group) == true ? id : nil
        })
        let adding = (file.objects[group]?["exceptions"] as? [String] ?? []).compactMap { file.objects[$0] }
            .filter { exception in
                guard let target = (exception["target"] as? String).flatMap({ file.objects[$0] }) else {
                    return exception["isa"] as? String != "PBXFileSystemSynchronizedBuildFileExceptionSet"
                }
                return !owners.contains(exception["target"] as? String ?? "")
                    && target["isa"] as? String == "PBXNativeTarget"
            }
        guard !adding.isEmpty else { return .success([:]) }
        guard let folder = file.location(of: group) else {
            return .failure(Failure(reason: "it can't place a folder synced with a group of \(project)"))
        }
        var added: [String?: Listing] = [:]
        for exception in adding {
            let target = exception["target"] as? String
            guard exception["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet" else {
                added[target, default: Listing()].folders[folder.canonicalPath] = []
                continue
            }
            for path in exception["membershipExceptions"] as? [String] ?? [] {
                let entry = (folder + "/" + path).canonicalPath
                if path.hasSuffix(".swift") {
                    added[target, default: Listing()].files.insert(entry)
                } else if FileManager.default.fileExists(atPath: entry + "/") {
                    added[target, default: Listing()].folders[entry] = []
                }
            }
        }
        return .success(added)
    }
}
