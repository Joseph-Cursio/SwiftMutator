import Foundation

/// A process and its descendants.
enum ProcessTree {
    /// How many times `terminate` and `terminateDescendants` list a tree, at most, while they stop it.
    static let maximumListings = 10

    /// Stops `root` and every descendant, parents first, and lists them again until a listing finds
    /// nothing new. Then it SIGKILLs them all, root last. Killed from one listing, a running `swift test`
    /// could start the next test bundle's runner between the listing and the kill, and that runner would
    /// be left running. A stopped process starts nothing, but a child can start one before its own stop,
    /// so the tree is listed again. `root` 0, a process that never launched, gets no signal: `kill` would
    /// read it as SwiftMutator's own process group.
    static func terminate(
        root: Int32,
        descendants: (Int32) -> [Int32],
        signal send: (_ pid: Int32, _ signal: Int32) -> Void
    ) {
        guard root > 0 else { return }
        send(root, SIGSTOP)
        let stopped = stopDescendants(of: root, descendants: descendants, signal: send)
        for pid in stopped + [root] {
            send(pid, SIGKILL) // SIGKILL also ends a stopped process
        }
    }

    /// `terminate` without ever signalling `root`, for SwiftMutator's own process, which
    /// `terminate(root: getpid())` would stop: stopped, it would never send the SIGKILLs. A listing that
    /// names `root` leaves it alone too.
    static func terminateDescendants(
        of root: Int32,
        descendants: (Int32) -> [Int32],
        signal send: (_ pid: Int32, _ signal: Int32) -> Void
    ) {
        guard root > 0 else { return }
        for pid in stopDescendants(of: root, descendants: descendants, signal: send) {
            send(pid, SIGKILL)
        }
    }

    /// SIGKILLs every process SwiftMutator started, and every process those started, but not SwiftMutator:
    /// for a run that is stopping, whose blocking steps (coverage, `cp`, `find`, `which`) no cancellation reaches.
    static func killDescendantsOfThisProcess() {
        terminateDescendants(of: getpid(), descendants: descendants(of:)) { pid, signal in
            kill(pid, signal)
        }
    }

    /// SIGSTOPs each descendant of `root` a listing names, and lists them again until a listing finds nothing
    /// new or `maximumListings` pass. Returns the processes it stopped, parents first. Never signals `root`.
    private static func stopDescendants(
        of root: Int32,
        descendants: (Int32) -> [Int32],
        signal send: (_ pid: Int32, _ signal: Int32) -> Void
    ) -> [Int32] {
        var stopped: [Int32] = []
        var seen: Set<Int32> = [root]
        for _ in 0..<maximumListings {
            let fresh = descendants(root).filter { seen.insert($0).inserted }
            guard !fresh.isEmpty else { break }
            fresh.forEach { send($0, SIGSTOP) }
            stopped += fresh
        }
        return stopped
    }

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
        // Listing SwiftMutator's own descendants, `ps` would name itself: a process already gone, and a new one
        // at each listing, so a listing would never find nothing new.
        var queue = (childrenByParent[root] ?? []).filter { $0 != listing.processIdentifier }
        while let pid = queue.first {
            queue.removeFirst()
            result.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }
    #endif
}
