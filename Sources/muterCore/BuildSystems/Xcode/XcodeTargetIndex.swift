/// The native targets of the projects read, by their products and names.
struct XcodeTargetIndex {
    /// Each target, by the ID of its product's file reference, per project.
    let byProduct: [FilePath: [String: String]]
    /// Each target, by its product's file name.
    let byProductName: [String: [XcodeTargetKey]]
    /// Each target, by its name.
    let byName: [String: [XcodeTargetKey]]

    init(_ projects: XcodeTestReach.Projects) {
        var products: [FilePath: [String: String]] = [:]
        var productNames: [String: [XcodeTargetKey]] = [:]
        var names: [String: [XcodeTargetKey]] = [:]
        for (project, file) in projects {
            for (id, object) in file.objects where object["isa"] as? String == "PBXNativeTarget" {
                let key = XcodeTargetKey(project: project, id: id)
                if let name = object["name"] as? String {
                    names[name, default: []].append(key)
                }
                guard let product = object["productReference"] as? String else { continue }
                products[project, default: [:]][product] = id
                if let path = file.objects[product]?["path"] as? String {
                    productNames[path.lastPathComponent, default: []].append(key)
                }
            }
        }
        byProduct = products
        byProductName = productNames
        byName = names
    }

    /// The targets that make the product the file reference `reference` of the project at `project` names: its
    /// own target's, a reference proxy's remote target, or else any target whose product has its file name.
    func targets(
            makingProduct reference: String,
            in project: FilePath,
            projects: XcodeTestReach.Projects
        ) -> [XcodeTargetKey] {
        if let id = byProduct[project]?[reference] {
            return [XcodeTargetKey(project: project, id: id)]
        }
        guard let file = projects[project], let object = file.objects[reference] else { return [] }
        if object["isa"] as? String == "PBXReferenceProxy", let proxy = object["remoteRef"] as? String,
           let remote = XcodeTestReach.remoteObject(of: proxy, in: project, projects: projects),
           let id = byProduct[remote.project]?[remote.id] {
            return [XcodeTargetKey(project: remote.project, id: id)]
        }
        return (object["path"] as? String).map { targets(makingProductNamed: $0.lastPathComponent) } ?? []
    }

    func targets(makingProductNamed name: String) -> [XcodeTargetKey] {
        byProductName[name] ?? []
    }

    /// The targets named `name`: those of the project at `project`, or else any project's.
    func targets(named name: String, preferring project: FilePath) -> [XcodeTargetKey] {
        let named = byName[name] ?? []
        let own = named.filter { $0.project == project }
        return own.isEmpty ? named : own
    }
}
