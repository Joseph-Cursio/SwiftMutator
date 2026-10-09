import Foundation

extension Foundation.Process: MuterProcess {}

extension Foundation.Process {
    #if !os(Linux)
    @objc
    #endif
    var processData: Data? {
        (standardOutput as? Pipe)?.readStringToEndOfFile()
    }

    func runProcess(
        url: String,
        arguments args: [String]
    ) -> Data? {
        let pipe = Pipe()
        standardOutput = pipe
        standardError = FileHandle.nullDevice
        executableURL = URL(fileURLWithPath: url)
        arguments = args

        try? run()

        let output = processData

        pipe.fileHandleForReading.closeFile()

        waitUntilExit()

        return output
    }

    func runCommand(url: String, arguments args: [String]) -> CommandResult? {
        // Standard error goes to a file: a command that filled its pipe while standard output was being read would
        // never exit.
        let errorsURL = FileManager.default.temporaryDirectory.appendingPathComponent("muter-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil),
              let errorsFile = try? FileHandle(forWritingTo: errorsURL)
        else { return nil }
        defer {
            try? errorsFile.close()
            try? FileManager.default.removeItem(at: errorsURL)
        }
        let output = Pipe()
        standardOutput = output
        standardError = errorsFile
        executableURL = URL(fileURLWithPath: url)
        arguments = args
        // Not `try?` then a read: a command that can't be started leaves the pipe open at this end, so the read
        // would never return.
        do { try run() } catch { return nil }
        let outputData = (try? output.fileHandleForReading.readToEnd()) ?? Data() // before waiting, as above
        waitUntilExit()
        let errorsData = FileManager.default.contents(atPath: errorsURL.path) ?? Data()
        return CommandResult(
            status: terminationStatus,
            endedBySignal: terminationReason == .uncaughtSignal,
            output: String(decoding: outputData, as: UTF8.self),
            errors: String(decoding: errorsData, as: UTF8.self)
        )
    }
}

private extension Pipe {
    func readStringToEndOfFile() -> Data? {
        let data: Data
        if #available(OSX 10.15.4, *) {
            data = (try? fileHandleForReading.readToEnd()) ?? Data()
        } else {
            data = fileHandleForReading.readDataToEndOfFile()
        }

        return data
    }
}
