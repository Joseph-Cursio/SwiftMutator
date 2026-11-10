import Foundation

extension MutationTestingDelegate {
    /// `schemata`'s marker for runs with `configuration` in `workingDirectory`, or the current directory if nil.
    func marker(
        of schemata: MutationSchema,
        using configuration: MuterConfiguration,
        workingDirectory: URL?
    ) -> ActivationMarker {
        let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let testRunFile = configuration.buildSystem == .xcodebuild
            ? configuration.xcodeWorker?.testRunFile ?? Self.muterTestRunFileName
            : nil
        return ActivationMarker(of: schemata, forWorkerIn: folder, testRunFile: testRunFile)
    }

    /// Empties `marker`'s place for the run about to start, so that it shows that run alone, and makes its folder. On
    /// the real disk, as a run's output is: its test process writes there, from outside this process.
    func clearActivation(of marker: ActivationMarker) {
        let files = FileManager.default
        try? files.removeItem(atPath: marker.path)
        try? files.removeItem(atPath: marker.reachedPath)
        try? files.createDirectory(
            atPath: marker.path.deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    /// What `marker` shows of the run that has just ended (`TestRun.activated`), and removes it.
    func readActivation(of marker: ActivationMarker) -> Bool? {
        defer { clearActivation(of: marker) }
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        return FileManager.default.fileExists(atPath: marker.reachedPath) ? false : nil
    }

    /// The test command's process for a run with `schemata` switched on, writing to `fileHandle`, in
    /// `workingDirectory`, or the current directory if nil. A mutant's run skips the build; a run with no mutant on
    /// skips it too when `alwaysSkippingBuild` is set.
    func testProcess(
        with configuration: MuterConfiguration,
        schemata: MutationSchema,
        and fileHandle: FileHandle,
        workingDirectory: URL? = nil,
        alwaysSkippingBuild: Bool = false
    ) throws -> Process {
        // A mutant's run skips the build the baseline did, and so does the run that times one with no mutant on.
        let skipsBuild = alwaysSkippingBuild || schemata != .null
        let testCommandArguments = skipsBuild
            ? configuration.testWithoutBuildArguments(with: Self.muterTestRunFileName)
            : configuration.testCommandArguments

        if skipsBuild, configuration.buildSystem == .xcodebuild, let worker = configuration.xcodeWorker {
            // Each run adds a result bundle and logs, which nothing reads, to the worker's derived data folder.
            // Emptied here, it holds one run's at most. Nothing in it is needed: the run tests the baseline's build.
            try? fileManager.removeItem(atPath: worker.derivedData)
        }

        let newProcess = process()

        // Set the muter marker only on the TEST process, not the shared build process (see
        // MuterProcessFactory) — it's not needed at build time and setting it there can suppress
        // xcodebuild's build-request.json.
        newProcess.environment?[isMuterRunningKey] = isMuterRunningValue

        if configuration.stopsAtFirstFailure {
            // `swift test` relays its test runners' output through its own standard output, which holds
            // output bound for a file 4 KiB at a time until it exits: a run stopped at its first failed test
            // would show that failure late, or lose its whole log. Set on the baselines and the timed test run
            // too, although they are never stopped, so they run as the mutants that stop do, and the time limit
            // derived from them allows for unbuffered output. Mutants run without it once a passing baseline's
            // failure-like line has turned stopping off for them.
            newProcess.environment?[unbufferedOutputKey] = unbufferedOutputValue
        }

        let marker = schemata == .null
            ? nil
            : marker(of: schemata, using: configuration, workingDirectory: workingDirectory)
        marker.map(clearActivation)

        if configuration.buildSystem == .swift {
            // SwiftPM keys its cache of compiled package manifests on the whole environment, so a variable of the
            // mutant's own made every run recompile every manifest. A worker's runs, baseline included, name one file
            // instead, written here before the run starts and read lazily by the generated code. A worker runs one
            // test process at a time (see PerformMutationTesting.testMutationsInParallel), so nothing rewrites it
            // during a run. Its second line names the run's activation marker.
            let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let activeMutantFile = Self.activeMutantFile(forWorkerIn: folder).path
            try writeFile(marker.map { schemata.id + "\n" + $0.path } ?? "", activeMutantFile)
            newProcess.environment?[activeMutantFileKey] = activeMutantFile
            // The same for each of the worker's runs too. `swift` stops at once if TMPDIR names no folder.
            let temporary = WorkerTemporaryFolder(forWorkerIn: folder, under: FileManager.default.temporaryDirectory)
            try makeFolder(temporary.path)
            newProcess.environment?.merge(temporary.environment) { _, own in own }
        } else if let marker {
            newProcess.environment?[schemata.id] = "YES"
            newProcess.environment?[activationMarkerKey] = marker.path
            // Also forward the activation var into an iOS Simulator test host. When xcodebuild spawns
            // tests in the simulator, CoreSimulator only propagates env vars prefixed `SIMCTL_CHILD_`
            // into the simulated process; a bare var set on this (parent) process never reaches the
            // test host, so the mutant wouldn't activate. Complements the xctestrun `EnvironmentVariables` path.
            newProcess.environment?["SIMCTL_CHILD_\(schemata.id)"] = "YES"
            newProcess.environment?["SIMCTL_CHILD_\(activationMarkerKey)"] = marker.path
        }

        if skipsBuild, let direct = configuration.directTestRun {
            let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let mutantFile = schemata == .null ? nil : schemata.filePath
            newProcess.arguments = ["-c", direct.script(in: folder, forMutantIn: mutantFile)]
            newProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        } else {
            newProcess.arguments = testCommandArguments
            newProcess.executableURL = URL(fileURLWithPath: configuration.testCommandExecutable)
        }
        // Workers that share a build have only a name each, which holds no folder to start in.
        if let folder = (skipsBuild ? configuration.directTestRun?.sharedBuild : nil) ?? workingDirectory {
            newProcess.currentDirectoryURL = folder
        }
        newProcess.standardOutput = fileHandle
        newProcess.standardError = fileHandle

        return newProcess
    }
}
