import Foundation

extension XcodeTargetSources {
    /// The workspace or project the test command opens, and the projects and local packages it opens with it.
    struct Opened {
        let container: (isWorkspace: Bool, path: FilePath)
        var projects: [FilePath] = []
        var packages: [FilePath] = []
    }

    /// What the project files read say: each project's file, what each non-test target compiles, the files each test
    /// target's Sources phases name, and the local packages, which count whole.
    struct Read {
        var projects: XcodeTestReach.Projects = [:]
        var targets: [XcodeTargetKey: Listing] = [:]
        var testTargets: [XcodeTargetKey: Listing] = [:]
        /// The local packages a workspace or a folder reference names, which count whole.
        var packages = Listing()
        /// The local packages a project references, each by the ID of its reference, which count when a target that
        /// counts uses one of their products.
        var packageReferences: [XcodeTargetKey: FilePath] = [:]

        /// Records `reference`, by the object `key` names, and gives the project it is, which is read next.
        mutating func record(_ reference: Reference, as key: XcodeTargetKey) -> FilePath? {
            switch reference {
            case let .project(location):
                return location

            case let .packageReference(location):
                packageReferences[key] = location.canonicalPath
                return nil

            case let .packageFolder(location):
                packages.folders[location.canonicalPath] = []
                return nil
            }
        }

        /// What the targets `reach` names compile, or every target when it's nil, with the packages it names, and the
        /// files of non-test targets that the test targets reached compile themselves.
        func listing(of reach: XcodeTestReach.Reach?) -> Listing {
            var everyTarget = Listing()
            for target in targets.values {
                everyTarget.merge(target)
            }
            var listing = packages
            guard let reach else {
                listing.merge(everyTarget)
                for folder in packageReferences.values {
                    listing.folders[folder] = []
                }
                return listing
            }
            for folder in reach.packages {
                listing.folders[folder] = []
            }
            let used = XcodeTestReach.localPackagesUsed(by: reach.targets, in: projects)
            for (reference, folder) in packageReferences
                where used?.contains(reference) ?? true || resolvesWithoutATarget(reference, at: folder) {
                listing.folders[folder] = []
            }
            for (key, target) in targets where reach.targets.contains(key) {
                listing.merge(target)
            }
            for (key, target) in testTargets where reach.targets.contains(key) {
                listing.files.formUnion(Self.files(of: target).filter(everyTarget.contains))
            }
            return listing
        }

        /// Whether Xcode builds the local package `reference` names, in the folder `folder`, whatever target uses it:
        /// no product dependency names it, so it is a root package, or it has a remote package's name, which it stands
        /// in for.
        private func resolvesWithoutATarget(_ reference: XcodeTargetKey, at folder: FilePath) -> Bool {
            var named = false
            var remoteNames: Set<String> = []
            for (project, file) in projects {
                for object in file.objects.values {
                    if object["package"] as? String == reference.id, project == reference.project {
                        named = true
                    }
                    if object["isa"] as? String == "XCRemoteSwiftPackageReference",
                       let url = object["repositoryURL"] as? String {
                        let name = url.lastPathComponent.lowercased()
                        remoteNames.insert(name.hasSuffix(".git") ? String(name.dropLast(4)) : name)
                    }
                }
            }
            return !named || remoteNames.contains(folder.lastPathComponent.lowercased())
        }

        /// Each Swift file `target` lists, as a file of its own or one in its folders.
        private static func files(of target: Listing) -> Set<FilePath> {
            var files = target.files
            for (folder, excluded) in target.folders {
                for path in FileManager.default.subpaths(atPath: folder) ?? []
                    where path.hasSuffix(".swift") && !excluded.contains(path) {
                    files.insert(folder + "/" + path)
                }
            }
            return files
        }
    }

    /// What an object of a project file references that has targets of its own: another project, a local package by
    /// a package reference, which counts when a target that counts uses it, or one as a folder, which counts whole.
    enum Reference {
        case project(FilePath)
        case packageReference(FilePath)
        case packageFolder(FilePath)
    }
}
