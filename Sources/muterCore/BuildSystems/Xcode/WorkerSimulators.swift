import Foundation

/// Makes, boots and removes the simulators an xcodebuild run's workers test on, one each, and removes those that runs
/// which have ended left behind.
protocol WorkerSimulating: Sendable {
    /// Deletes the worker simulators left behind by an earlier run of `mutatedProject`, whatever ran it, and by any
    /// run, of any project, whose process no longer runs. The caller holds `mutatedProject`'s lock, so no run of it
    /// is under way. Does nothing when simctl can't list its simulators.
    func sweep(_ mutatedProject: URL) async

    /// `count` new simulators like the one `destination`, the run's first `-destination`, names, for the workers of a
    /// run of `mutatedProject`, in worker order. Each is recorded as soon as simctl has made it, so that `removeAll()`
    /// deletes it. Throws `WorkerSimulatorsUnavailable` when they can't all be made, once it has deleted those it made,
    /// or a CancellationError, leaving them to `removeAll()`.
    func prepare(_ count: Int, like destination: String, for mutatedProject: URL) async throws -> [WorkerSimulator]

    /// Boots `simulators`, all at once, and returns once each has finished booting. Throws
    /// `WorkerSimulatorsUnavailable` when one doesn't boot, or a CancellationError.
    func boot(_ simulators: [WorkerSimulator]) async throws

    /// Deletes every simulator `prepare` made that hasn't been deleted yet, all at once, whether or not they are
    /// booted. One whose delete fails, or is killed, as a stop kills this process's children, stays recorded, so that
    /// a later call tries it once more; one that no call deletes is left for the next run's sweep. Starts no process
    /// when there is none.
    func removeAll() async
}

/// A simulator made for one worker.
struct WorkerSimulator: Equatable, Sendable {
    let udid: String
    /// Its name, which says whose it is (`WorkerSimulatorName`).
    let name: String
    /// The `-destination` that names it: `platform=iOS Simulator,id=<udid>`, or `id=<udid>` when neither the run's
    /// destination nor the runtime names the platform.
    let destination: String
}

/// Why a run's workers can't have simulators of their own, completing a sentence such as "Testing one mutant at a
/// time: …".
struct WorkerSimulatorsUnavailable: Error, Equatable, CustomStringConvertible {
    let reason: String
    /// Whether it is that the run's first `-destination` names no available simulator, or more than one, as a
    /// device's bare `id=` does. One worker then tests on that destination without a word, unless
    /// `oneWorkerSimulator` asked for a simulator of its own.
    var destinationUnresolved = false

    var description: String { reason }
}

/// The name of a worker's simulator: `swiftmutator-<project>-<pid>-<start>-w<worker>`. `<project>` is the first 8 hex
/// digits of the SHA-256 of the mutated project's path, and `<pid>` and `<start>` are the SwiftMutator process that
/// made it, as `RecordedProcess` tells it apart from a later process given the same ID. No other simulator is named
/// so: not the user's, not swift-mutation-testing's `XMR-…`, and not the `swiftmutator-probe-…` of experiments.
struct WorkerSimulatorName: Equatable, Sendable {
    static let prefix = "swiftmutator-"

    let projectHash: String
    let owner: RecordedProcess
    let worker: Int

    init(projectHash: String, owner: RecordedProcess, worker: Int) {
        self.projectHash = projectHash
        self.owner = owner
        self.worker = worker
    }

    /// The name `text` is, or nil if it isn't a worker simulator's.
    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix) else {
            return nil
        }
        let parts = text.dropFirst(Self.prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].count == 8,
              parts[0].allSatisfy({ "0123456789abcdef".contains($0) }),
              parts[3].hasPrefix("w"),
              let id = Self.number(parts[1]).flatMap(Int32.init),
              let started = Self.number(parts[2]).flatMap(UInt64.init),
              let workerNumber = Self.number(parts[3].dropFirst()).flatMap(Int.init)
        else {
            return nil
        }
        projectHash = String(parts[0])
        owner = RecordedProcess(id: id, started: started)
        self.worker = workerNumber
    }

    var text: String {
        "\(Self.prefix)\(projectHash)-\(owner.id)-\(owner.started)-w\(worker)"
    }

    /// The first 8 hex digits of the SHA-256 of `mutatedProject`'s standardized path.
    static func projectHash(of mutatedProject: URL) -> String {
        String(FileDigest.sha256(of: Data(mutatedProject.standardizedFileURL.path.utf8)).prefix(8))
    }

    /// `text` if it is decimal digits alone: `Int("+1")` would take a sign.
    private static func number(_ text: Substring) -> String? {
        !text.isEmpty && text.allSatisfy { ("0"..."9").contains($0) } ? String(text) : nil
    }
}

/// Runs `xcrun simctl` for a run's worker simulators, and records the ones it made, so they are deleted however the
/// run ends: by `removeAll()` once the work has ended, or by the next run's sweep after a stop at once, a SIGKILL or a
/// crash.
final class WorkerSimulators: WorkerSimulating, @unchecked Sendable { // `made` is behind `lock`
    static let xcrun = "/usr/bin/xcrun"
    /// How long simctl may take to list, make or delete a simulator, in seconds: each takes well under a second, or
    /// about 3.4 for deleting a booted one.
    static let simctlTimeLimit: TimeInterval = 60
    /// How long a simulator may take to boot, in seconds. A fresh one took 28 to 54 seconds on a busy Mac.
    static let bootTimeLimit: TimeInterval = 300

    @Dependency(\.process)
    private var process: ProcessFactory
    /// This process, which names the simulators it makes, or nil if its start time can't be read.
    private let owner: RecordedProcess?
    private let isRunning: @Sendable (RecordedProcess) -> Bool
    private let lock = NSLock()
    /// The UDIDs of the simulators made and not yet deleted, in the order they were made.
    private var made: [String] = []

    init(
        owner: RecordedProcess? = RecordedProcess(getpid()),
        isRunning: @escaping @Sendable (RecordedProcess) -> Bool = {
            MutatedProjectLock.startTime(of: $0.id) == $0.started
        }
    ) {
        self.owner = owner
        self.isRunning = isRunning
    }

    /// The UDIDs of the simulators made and not yet deleted, in the order they were made.
    var recorded: [String] { lock.withLock { made } }

    func sweep(_ mutatedProject: URL) async {
        guard let list = await list() else {
            return
        }
        let project = WorkerSimulatorName.projectHash(of: mutatedProject)
        let ours = Set(recorded)
        let leftovers = list.devices.filter { device in
            guard !ours.contains(device.udid), let name = WorkerSimulatorName(device.name) else {
                return false
            }
            return name.projectHash == project || !isRunning(name.owner)
        }
        await delete(leftovers.map(\.udid))
    }

    func prepare(_ count: Int, like destination: String, for mutatedProject: URL) async throws -> [WorkerSimulator] {
        guard let owner else {
            throw WorkerSimulatorsUnavailable(reason: "SwiftMutator can't read when its own process started, which "
                + "names its simulators")
        }
        let base = try await baseDevice(namedBy: destination)
        let platform = SimulatorDestination(destination: destination)?.platform ?? base.runtime?.destinationPlatform
        let project = WorkerSimulatorName.projectHash(of: mutatedProject)
        var simulators: [WorkerSimulator] = []
        for worker in 0..<max(count, 0) {
            try Task.checkCancellation()
            let name = WorkerSimulatorName(projectHash: project, owner: owner, worker: worker).text
            // A booted simulator can't be cloned (SimError 405), and SwiftMutator never shuts the user's down: a new
            // one of its kind is made instead, without the user's simulator data. The baseline, the user's own test
            // command, may still shut it down, as xcodebuild's parallel testing does to clone it.
            let arguments = base.isShutdown
                ? ["clone", base.udid, name]
                : ["create", name, base.deviceTypeIdentifier, base.runtimeIdentifier]
            let result = await simctl(arguments, timeLimit: Self.simctlTimeLimit)
            let udid = result?.output.trimmed ?? ""
            guard let result, result.succeeded, UUID(uuidString: udid) != nil else {
                // Stopping killed simctl, and `removeAll()` deletes what was made once the work has ended.
                try Task.checkCancellation()
                await remove(simulators.map(\.udid))
                throw WorkerSimulatorsUnavailable(reason: Self.failure(of: arguments, result))
            }
            lock.withLock { made.append(udid) }
            let named = platform.map { "platform=\($0)," } ?? ""
            simulators.append(WorkerSimulator(udid: udid, name: name, destination: "\(named)id=\(udid)"))
        }
        return simulators
    }

    func boot(_ simulators: [WorkerSimulator]) async throws {
        // `-b` boots a simulator that isn't booted, then waits until it has finished booting, so no worker starts on a
        // simulator that is still starting.
        let failures = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, simulator) in simulators.enumerated() {
                group.addTask { [self] in
                    let arguments = ["bootstatus", simulator.udid, "-b"]
                    let result = await simctl(arguments, timeLimit: Self.bootTimeLimit, killedIfCancelled: true)
                    return (index, result?.succeeded == true ? nil : Self.failure(of: arguments, result))
                }
            }
            var failures: [(Int, String)] = []
            for await (index, failure) in group {
                if let failure { failures.append((index, failure)) }
            }
            return failures.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        if let failure = failures.first {
            throw WorkerSimulatorsUnavailable(reason: failure)
        }
    }

    func removeAll() async {
        await remove(recorded)
    }
}

private extension WorkerSimulators {
    /// The available simulator `destination` names, which the workers' simulators are made like.
    func baseDevice(namedBy destination: String) async throws -> SimctlDevice {
        guard let wanted = SimulatorDestination(destination: destination) else {
            throw WorkerSimulatorsUnavailable(
                reason: "`-destination \(destination)` names no simulator", destinationUnresolved: true
            )
        }
        guard let list = await list() else {
            throw WorkerSimulatorsUnavailable(reason: "SwiftMutator couldn't read simctl's list of simulators")
        }
        guard let base = wanted.resolve(in: list) else {
            throw WorkerSimulatorsUnavailable(
                reason: "no available simulator matches `-destination \(destination)`, or more than one does",
                destinationUnresolved: true
            )
        }
        return base
    }

    /// simctl's list of simulators, or nil if it gave none that can be read.
    func list() async -> SimctlDeviceList? {
        // Standard output alone: simctl can warn on standard error.
        guard let result = await simctl(["list", "devices", "--json"], timeLimit: Self.simctlTimeLimit),
              result.succeeded
        else {
            return nil
        }
        return SimctlDeviceList(json: Data(result.output.utf8))
    }

    /// Deletes `udids`, which `prepare` made, and forgets each once its delete has succeeded. Until then the sweep
    /// skips it, and `removeAll()` tries it again: a stop kills the deletes under way while the work runs, but not
    /// those once it has ended.
    func remove(_ udids: [String]) async {
        let deleted = Set(await delete(udids))
        lock.withLock { made.removeAll { deleted.contains($0) } }
    }

    /// Deletes `udids` all at once, booted or not, and returns those whose delete succeeded.
    @discardableResult
    func delete(_ udids: [String]) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for udid in udids {
                group.addTask { [self] in
                    let result = await simctl(["delete", udid], timeLimit: Self.simctlTimeLimit)
                    return result?.succeeded == true ? udid : nil
                }
            }
            var deleted: [String] = []
            for await udid in group {
                if let udid { deleted.append(udid) }
            }
            return deleted
        }
    }

    /// Runs `xcrun simctl <arguments>`, or nil if it couldn't be started. If `killedIfCancelled`, cancelling the
    /// calling task kills it, as waiting for a command ignores cancellation, and a task cancelled already starts
    /// none: a boot that a failed baseline cancels would otherwise hold up the run's end for as long as the boot takes.
    /// Never a delete, which a stop's own kill reaches, and which a cancelled boot's cleanup still needs.
    func simctl(
        _ arguments: [String],
        timeLimit: TimeInterval,
        killedIfCancelled: Bool = false
    ) async -> CommandResult? {
        let simctl = process()
        guard killedIfCancelled else {
            return await simctl.runCommand(url: Self.xcrun, arguments: ["simctl"] + arguments, timeLimit: timeLimit)
        }
        guard !Task.isCancelled else {
            return nil
        }
        return await withTaskCancellationHandler {
            await simctl.runCommand(url: Self.xcrun, arguments: ["simctl"] + arguments, timeLimit: timeLimit)
        } onCancel: {
            simctl.terminateTreeInBackground()
        }
    }

    /// Why `xcrun simctl <arguments>` didn't do its job, as `result` shows: the last line of what it wrote.
    static func failure(of arguments: [String], _ result: CommandResult?) -> String {
        let command = "`xcrun simctl \(arguments.joined(separator: " "))`"
        guard let result else {
            return "\(command) couldn't be started"
        }
        if result.timedOut {
            let limit = arguments.first == "bootstatus" ? bootTimeLimit : simctlTimeLimit
            return "\(command) didn't finish within \(Int(limit)) seconds"
        }
        if result.succeeded {
            return "\(command) printed no UDID"
        }
        let ended = result.endedBySignal
            ? "was killed by signal \(result.status)"
            : "failed with exit code \(result.status)"
        // simctl's last line says what went wrong, after one that says only that something did.
        let lastLine = [result.errors, result.output].lazy
            .compactMap { text in
                text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.last { !$0.isEmpty }
            }
            .first
        return "\(command) \(ended)" + (lastLine.map { ": \($0)" } ?? "")
    }
}
