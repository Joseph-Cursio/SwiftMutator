import Foundation

/// A process and its descendants. Under xcodebuild, a simulator runs the tests in a process it starts itself, the
/// test host or `xctest`, which isn't a descendant of xcodebuild. Killing xcodebuild is enough: the simulator then ends
/// that process within 0.2 seconds, hosted or not, even with its main thread blocked (Xcode 27.1, iOS 26.5 and 27.0).
enum ProcessTree {
    /// How many times a stop lists a tree, at most: `terminate`'s, `terminateDescendants`', and a suspension's.
    static let maximumListings = 10

    /// How long a suspension's stop waits after a round of SIGSTOPs before it lists the tree again and checks that they
    /// held. On macOS a SIGSTOP sent while a process execs can be lost, and the process runs on: of 400 sent 0–3 ms
    /// after `/bin/sh` started (macOS 27), 62 didn't hold, each seen running again within 2 ms, and each second SIGSTOP
    /// held. A process stops only once it is done starting a child, too. Stopping a shell that kept starting
    /// `/bin/sleep 30 &` by listing again at once, with no second stop, left a process sent SIGSTOP running 100 ms
    /// later in 223 of 600 tries, and a child never listed in 19, most of them started by a shell whose own stop was
    /// lost. With this pause, a new listing and a second SIGSTOP for whatever still ran, in none of 600.
    static let settlingMicroseconds: useconds_t = 20_000

    /// What a stop does after each round of SIGSTOPs, before it lists the tree again: it pauses, then stops again each
    /// process it stopped that isn't stopped or ended. A suspension settles, since its processes must stay stopped. A
    /// kill doesn't: its SIGKILLs follow the stops at once, and a pause would hold up every kill of a run, and a second
    /// signal's stop at once behind the sweep under way.
    struct Settling {
        var pause: () -> Void = ProcessTree.settle
        var isStoppedOrEnded: (Int32) -> Bool = ProcessTree.isStoppedOrEnded(_:)
    }

    /// The pause after a round of SIGSTOPs.
    static func settle() {
        usleep(settlingMicroseconds)
    }

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

    /// Suspends SwiftMutator, as Ctrl-Z would have, with every process it started: each leads a process group of its
    /// own, so a terminal's Ctrl-Z reaches SwiftMutator alone. Returns once SwiftMutator is continued, as by `fg` or
    /// `bg`, having continued them too.
    static func suspendThisProcessAndItsDescendants() {
        let me = getpid()
        _ = stopDescendants(of: me, descendants: descendants(of:), settling: Settling()) { pid, signal in
            kill(pid, signal)
        }
        // SIGSTOP, not SIGTSTP: SwiftMutator observes SIGTSTP, so it would only come back here. The rest of this
        // process stops with this thread.
        kill(me, SIGSTOP)
        // Listed again: a process stopped above may have ended since, its ID given to another. None of them started
        // a process while stopped.
        for pid in descendants(of: me) {
            kill(pid, SIGCONT)
        }
    }

    /// SIGSTOPs each descendant of `root` a listing names, and lists them again until a listing finds nothing
    /// new or `maximumListings` pass. With `settling`, a round's stops must hold too: after each round it pauses, and
    /// stops again what still runs before it lists again. Returns the processes it stopped, parents first. Never
    /// signals `root`.
    static func stopDescendants(
        of root: Int32,
        descendants: (Int32) -> [Int32],
        settling: Settling? = nil,
        signal send: (_ pid: Int32, _ signal: Int32) -> Void
    ) -> [Int32] {
        var stopped: [Int32] = []
        var seen: Set<Int32> = [root]
        var stoppedAgain = false
        for _ in 0..<maximumListings {
            let fresh = descendants(root).filter { seen.insert($0).inserted }
            guard !fresh.isEmpty || stoppedAgain else { break }
            fresh.forEach { send($0, SIGSTOP) }
            stopped += fresh
            guard let settling else { continue }
            // Checked at once, a stop that didn't hold could still show as stopped, and a child that a process was
            // starting as its stop came could be missing from the next listing.
            settling.pause()
            let runningOn = stopped.filter { !settling.isStoppedOrEnded($0) }
            runningOn.forEach { send($0, SIGSTOP) }
            stoppedAgain = !runningOn.isEmpty
        }
        return stopped
    }

    /// Whether the process with this ID is stopped, or has ended: a zombie, or gone.
    static func isStoppedOrEnded(_ pid: Int32) -> Bool {
        #if os(macOS)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // No such process leaves `size` 0.
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return true }
        return [SSTOP, SZOMB].contains(Int32(info.kp_proc.p_stat))
        #else
        // proc(5): the state is the first field after the command, which is in parentheses and may hold spaces and
        // parentheses itself.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let commandEnd = stat.lastIndex(of: ")"),
              let state = stat[stat.index(after: commandEnd)...].split(separator: " ").first
        else { return true }
        // Stopped ("T", or "t" while traced), a zombie, or being reaped ("X", or "x" before Linux 3.14).
        return ["T", "t", "Z", "X", "x"].contains(state)
        #endif
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
        // Read before waiting: a listing of a few thousand processes overfills the pipe, and `ps` would never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
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
