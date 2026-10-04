import Foundation

/// A process and its descendants.
enum ProcessTree {
    /// Every transitive child of `root`, each parent before its children.
    static func descendants(of root: Int32) -> [Int32] {
        #if os(macOS)
        var result: [Int32] = []
        // Each process's children are listed at a different moment, so a listing could in theory name a
        // process already walked, its ID reused; skipping those keeps the walk finite.
        var seen: Set<Int32> = [root]
        var queue = children(of: root)
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue += children(of: pid)
        }
        return result
        #else
        return descendantsFromProcessList(of: root)
        #endif
    }

    #if os(macOS)
    /// `parent`'s direct children, from the kernel, without starting `ps`.
    private static func children(of parent: Int32) -> [Int32] {
        // Without a buffer this returns room for every process on the system, not the number of children.
        let estimate = proc_listchildpids(parent, nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) * 2) // room for processes started meanwhile
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        return Array(pids.prefix(Int(max(count, 0))))
    }
    #else
    /// All transitive child PIDs of `root`, discovered from `ps -eo pid,ppid`.
    private static func descendantsFromProcessList(of root: Int32) -> [Int32] {
        let listing = Foundation.Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-eo", "pid,ppid"]
        let pipe = Pipe()
        listing.standardOutput = pipe
        guard (try? listing.run()) != nil else { return [] }
        listing.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var childrenByParent: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " }).compactMap { Int32($0) }
            guard cols.count == 2 else { continue }
            childrenByParent[cols[1], default: []].append(cols[0])
        }

        var result: [Int32] = []
        var queue = childrenByParent[root] ?? []
        while let pid = queue.first {
            queue.removeFirst()
            result.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }
    #endif
}
