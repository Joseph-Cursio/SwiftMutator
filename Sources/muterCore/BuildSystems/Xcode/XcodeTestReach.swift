import Foundation

/// A native target, by its ID in the project at `project`, a path with its links resolved.
struct XcodeTargetKey: Hashable {
    let project: FilePath
    let id: String
}

/// Which targets an Xcode scheme's test action builds, so that discovery leaves out the files of a target it never
/// builds, as an unused tool's, whose mutants no test could kill. It starts from the targets the scheme builds for
/// testing, tests, or whose settings its tests expand, and those its test plans test, and follows, at any depth, the
/// targets each depends on, explicitly or by linking or embedding another target's product, its host app, and the
/// target it tests, across the projects read. Nil when SwiftMutator can't tell: no `-scheme`, no scheme file, a scheme
/// that names no test target and lets Xcode make its test plan, or a reference, dependency or host it can't follow.
/// The packages a scheme names are left alone: a local package counts whole (`XcodeTargetSources`).
enum XcodeTestReach {
    /// A project read, by its path with its links resolved.
    typealias Projects = [FilePath: ProjectFile]

    /// The kinds of bundle a test host or bundle loader setting names, by the extension of its product.
    static let bundleExtensions: Set = ["app", "appex", "framework", "bundle", "xctest", "xpc"]

    /// The targets the scheme's test action builds, and the local packages it names, which it builds whole.
    struct Reach: Equatable {
        let targets: Set<XcodeTargetKey>
        let packages: Set<FilePath>
    }

    static func reached(
        in projects: Projects,
        container: (isWorkspace: Bool, path: FilePath),
        arguments: [String],
        fileManager: FileSystemManager
    ) -> Reach? {
        let given = XcodebuildArguments(arguments).arguments.last { argument in
            argument.kind == .option && argument.name == "-scheme" && argument.written.count > 1
        }
        guard let schemeName = given?.written[1],
              let (scheme, base) = scheme(named: schemeName, in: container, projects: projects)
        else {
            return nil
        }
        var references = scheme.targets
        for plan in scheme.testPlans {
            let path = XcodeBuildConditions.lexicallyNormalized(base + "/" + plan)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let targets = XcodeScheme.targets(ofTestPlan: text)
            else {
                return nil
            }
            references += targets
        }
        let namesNoTest = scheme.testPlans.isEmpty && !scheme.targets.contains { reference in
            key(of: reference, base: base, projects: projects).map { key in
                isATestTarget(projects[key.project]?.objects[key.id] ?? [:])
            } ?? false
        }
        if scheme.autocreatesATestPlan, namesNoTest {
            return nil
        }

        var seeds: [XcodeTargetKey] = []
        var packages: Set<FilePath> = []
        for reference in references {
            let path = XcodeBuildConditions.lexicallyNormalized(
                reference.container.isEmpty ? base : base + "/" + reference.container
            )
            if !path.hasSuffix(".xcodeproj"), fileManager.fileExists(atPath: path + "/Package.swift") {
                packages.insert(path.canonicalPath)
                continue
            }
            guard let key = key(of: reference, base: base, projects: projects) else {
                return nil
            }
            seeds.append(key)
        }
        return closure(of: seeds, in: projects).map { Reach(targets: $0, packages: packages) }
    }

    /// Whether `target`, a project file's object, is a test target.
    static func isATestTarget(_ target: [String: Any]) -> Bool {
        XcodeTargetSources.testProductTypes.contains(target["productType"] as? String ?? "")
    }

    /// The scheme named `name`, shared or a user's, of the workspace or project `container`, or of a project a
    /// workspace opens, with the folder its references are relative to: the one that holds its workspace or project.
    /// As xcodebuild reads them: shared ones, and the user's own. Nil when it finds none, or one in more than one
    /// container, as it can't tell which xcodebuild opens, or none but another user's of that name, which xcodebuild
    /// doesn't read, so that it may make a scheme of its own.
    private static func scheme(
        named name: String,
        in container: (isWorkspace: Bool, path: FilePath),
        projects: Projects
    ) -> (XcodeScheme, base: FilePath)? {
        let containers = [container.path] + (container.isWorkspace ? projects.keys.sorted() : [])
        var found: [(text: String, base: FilePath)] = []
        for folder in containers {
            for schemes in ["xcshareddata", "xcuserdata/\(NSUserName()).xcuserdatad"] {
                let path = "\(folder)/\(schemes)/xcschemes/\(name).xcscheme"
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    found.append((text, folder.deletingLastPathComponent))
                    break
                }
            }
        }
        guard found.count == 1, let only = found.first else { return nil }
        return XcodeScheme(only.text).map { ($0, only.base) }
    }

    /// The target `reference` names, of a project read, its container relative to `base`; nil if it names none.
    private static func key(
        of reference: XcodeScheme.TargetReference,
        base: FilePath,
        projects: Projects
    ) -> XcodeTargetKey? {
        let path = XcodeBuildConditions.lexicallyNormalized(
            reference.container.isEmpty ? base : base + "/" + reference.container
        ).canonicalPath
        let isa = projects[path]?.objects[reference.identifier]?["isa"] as? String
        guard isa == "PBXNativeTarget" || isa == "PBXAggregateTarget" else {
            return nil
        }
        return XcodeTargetKey(project: path, id: reference.identifier)
    }

    /// `seeds` and every target they lead to, at any depth; nil if one leads somewhere SwiftMutator can't follow.
    private static func closure(of seeds: [XcodeTargetKey], in projects: Projects) -> Set<XcodeTargetKey>? {
        let index = XcodeTargetIndex(projects)
        var reached: Set<XcodeTargetKey> = []
        var toFollow = seeds
        while let key = toFollow.popLast() {
            guard reached.insert(key).inserted else { continue }
            guard let next = targets(after: key, in: projects, index: index) else { return nil }
            toFollow += next
        }
        return reached
    }

    /// The targets `key`'s target leads to: those it depends on, explicitly or by linking or embedding their
    /// products, its host app, and the target it tests; nil if one can't be followed.
    private static func targets(
        after key: XcodeTargetKey,
        in projects: Projects,
        index: XcodeTargetIndex
    ) -> [XcodeTargetKey]? {
        guard let file = projects[key.project], let target = file.objects[key.id],
              var next = explicitDependencies(of: target, in: key.project, projects: projects)
        else {
            return nil
        }

        // A product in any phase, linked, embedded or copied as a resource, makes Xcode build its target first.
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { file.objects[$0] }
        for phase in phases {
            for buildFile in (phase["files"] as? [String] ?? []).compactMap({ file.objects[$0] }) {
                guard let reference = buildFile["fileRef"] as? String else { continue }
                next += index.targets(makingProduct: reference, in: key.project, projects: projects)
            }
        }

        guard let hosts = hostTargets(of: target, in: key.project, file: file, index: index) else { return nil }
        next += hosts
        let attributes = (file.objects[file.rootObjectID]?["attributes"] as? [String: Any])?["TargetAttributes"]
        if let tested = ((attributes as? [String: Any])?[key.id] as? [String: Any])?["TestTargetID"] as? String,
           file.objects[tested] != nil {
            next.append(XcodeTargetKey(project: key.project, id: tested))
        }
        return next
    }

    /// The local package references, by their objects' IDs, whose products the targets in `reached` use; nil when one
    /// uses a product of a package it doesn't name, which could be any of them.
    static func localPackagesUsed(by reached: Set<XcodeTargetKey>, in projects: Projects) -> Set<XcodeTargetKey>? {
        var used: Set<XcodeTargetKey> = []
        for key in reached {
            guard let file = projects[key.project], let target = file.objects[key.id] else { continue }
            var products = target["packageProductDependencies"] as? [String] ?? []
            for id in (target["dependencies"] as? [String] ?? []) + (target["buildPhases"] as? [String] ?? []) {
                let object = file.objects[id] ?? [:]
                products += (object["productRef"] as? String).map { [$0] } ?? []
                products += (object["files"] as? [String] ?? []).compactMap { buildFile in
                    file.objects[buildFile]?["productRef"] as? String
                }
            }
            for product in products {
                guard let dependency = file.objects[product] else { continue }
                guard let package = dependency["package"] as? String else { return nil }
                used.insert(XcodeTargetKey(project: key.project, id: package))
            }
        }
        return used
    }

    /// The object a container item proxy in the project at `project` names: in that project, or in another one
    /// read that a file reference names; nil if it's in a project not read.
    static func remoteObject(of proxy: String, in project: FilePath, projects: Projects) -> XcodeTargetKey? {
        guard let file = projects[project], let item = file.objects[proxy],
              let portal = item["containerPortal"] as? String, let remote = item["remoteGlobalIDString"] as? String
        else {
            return nil
        }
        if portal == file.rootObjectID {
            return XcodeTargetKey(project: project, id: remote)
        }
        guard let location = file.location(of: portal)?.canonicalPath, projects[location] != nil else { return nil }
        return XcodeTargetKey(project: location, id: remote)
    }
}
