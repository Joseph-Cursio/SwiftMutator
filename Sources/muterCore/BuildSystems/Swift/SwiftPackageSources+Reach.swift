extension SwiftPackageSources {
    /// A target, by its name, of the package at index `package` in a list of packages.
    private struct Reference: Hashable {
        let package: Int
        let target: String
    }

    /// The targets of `packages`, the tested package first, whose code a test can run, so whose mutants a test can
    /// kill: those the tested package's test targets depend on, and its executable targets, which a test can run as a
    /// process, and those they depend on in turn, at any depth, through targets of their own package and products of
    /// the others. A file no such target compiles, as an example's or an unused target's, has mutants no test can kill.
    /// A product no package in `packages` has is a remote package's, whose files aren't in the project. Every target
    /// when the tested package has no test target, or describe didn't name one: what the tests reach can't be told
    /// then. It keeps a superset of the files a coverage run names, as a run without coverage, such as one of
    /// `--mutant`, must: a test bundle links only what its test target depends on.
    static func reachedByTheTests(_ packages: [Package]) -> [PackageTarget] {
        let everyTarget = packages.flatMap(\.targets)
        guard let tested = packages.first, !tested.testTargets.isEmpty,
              !packages.flatMap({ $0.targets + $0.testTargets }).contains(where: { $0.name == nil })
        else {
            return everyTarget
        }

        let targets = Dictionary(
            packages.enumerated().flatMap { index, package in
                package.targets.compactMap { target in
                    target.name.map { (Reference(package: index, target: $0), target) }
                }
            }
        ) { first, _ in first }
        let productTargets = Dictionary(
            packages.enumerated().flatMap { index, package in
                package.products.map { name, names in (name, names.map { Reference(package: index, target: $0) }) }
            },
            uniquingKeysWith: +
        )
        func dependencies(of target: PackageTarget, in package: Int) -> [Reference] {
            target.targetDependencies.map { Reference(package: package, target: $0) }
                + target.productDependencies.flatMap { productTargets[$0] ?? [] }
        }

        var reached: Set<Reference> = []
        var toFollow = tested.testTargets.flatMap { dependencies(of: $0, in: 0) }
            + tested.targets.filter { $0.type == "executable" }.compactMap { target in
                target.name.map { Reference(package: 0, target: $0) }
            }
        while let reference = toFollow.popLast() {
            guard let target = targets[reference], reached.insert(reference).inserted else { continue }
            toFollow += dependencies(of: target, in: reference.package)
        }
        return packages.enumerated().flatMap { index, package in
            package.targets.filter { target in
                target.name.map { reached.contains(Reference(package: index, target: $0)) } ?? false
            }
        }
    }
}
