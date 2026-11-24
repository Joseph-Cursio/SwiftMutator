@testable import muterCore
import Foundation

/// Describe's answers, and the packages on disk, that the tests are given.
extension SwiftPackageSourcesTests {
    func files(in root: FilePath) async -> Result<[FilePath], SwiftPackageSources.Failure> {
        await SwiftPackageSources.files(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: swift, arguments: arguments)
        ) { [process] in process }
    }

    /// Answers `swift package describe` of each package path with a description of its `targets`, whose local
    /// packages are its `dependencies` (nil for a package from a repository), and whose products are its `products`'
    /// (each product's targets by its name), and fails for any other.
    func describing(
        _ targets: [String: [String]],
        dependencies: [String: [String?]] = [:],
        products: [String: [String: [String]]] = [:]
    ) {
        process.commandResult = { command in
            guard let path = command.firstIndex(of: "--package-path").map({ command[$0 + 1] }),
                  let packageTargets = targets[path]
            else {
                return self.result(status: 1)
            }
            return self.result(output: self.description(
                path: path,
                targets: packageTargets,
                dependencies: dependencies[path] ?? [],
                products: products[path] ?? [:]
            ))
        }
    }

    /// A description as `swift package describe --type json` gives it.
    func description(
        path: String,
        targets: [String],
        dependencies: [String?] = [],
        products: [String: [String]] = [:]
    ) -> String {
        let dependencyEntries = dependencies.map { path in
            path.map { #"{"identity": "local", "path": "\#($0)", "type": "fileSystem"}"# }
                ?? #"{"identity": "remote", "type": "sourceControl", "url": "https://example.com/remote.git"}"#
        }
        let productEntries = products.sorted { $0.key < $1.key }.map { name, targets in
            #"{"name": "\#(name)", "type": {"library": ["automatic"]}, "targets": \#(quoted(targets))}"#
        }
        return """
        {"name": "Project", "path": "\(path)", "dependencies": [\(dependencyEntries.joined(separator: ", "))],
         "products": [\(productEntries.joined(separator: ", "))], "targets": [\(targets.joined(separator: ", "))]}
        """
    }

    /// A target as describe gives it, named after its folder unless `name` is given, which depends on the targets of
    /// its package named in `dependsOn` and the products of other packages named in `products`. Describe leaves out
    /// either list when it is empty.
    func target(
        _ type: String,
        path: String,
        sources: [String],
        name: String? = nil,
        dependsOn: [String] = [],
        products: [String] = []
    ) -> String {
        let targetName = name ?? path.lastPathComponent
        let dependencies = (dependsOn.isEmpty ? "" : #", "target_dependencies": \#(quoted(dependsOn))"#)
            + (products.isEmpty ? "" : #", "product_dependencies": \#(quoted(products))"#)
        return #"{"name": "\#(targetName)", "type": "\#(type)", "path": "\#(path)", "sources": \#(quoted(sources))"#
            + dependencies + "}"
    }

    private func quoted(_ strings: [String]) -> String {
        "[" + strings.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    func makePackage(in directory: String, manifest: String, files: [String]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try manifest.write(toFile: directory + "/Package.swift", atomically: true, encoding: .utf8)
        try makeFiles(files, in: directory)
    }

    func makeFiles(_ files: [String], in directory: String) throws {
        for file in files {
            let path = directory + "/" + file
            try FileManager.default.createDirectory(
                atPath: path.deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "let value = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }
}
