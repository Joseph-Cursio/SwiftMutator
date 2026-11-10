import Foundation
@testable import muterCore
import TestingExtensions

private enum AcceptanceTestsError: Error {
    case reason(String)
}

extension AcceptanceTests {
    var rootTestDirectory: String {
        String(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .withoutScheme()
        )
    }

    var muterOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_output.txt")
        }
    }

    var mutersOutputWithTestPlan: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_output_with_test_plan.txt")
        }
    }

    var muterXcodeOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_xcode_output.txt")
        }
    }

    var muterFilesToMutateOutput: String {
        get throws {
            try contentsOfFileAsString(
                "\(rootTestDirectory)/samples/muters_files_to_mutate_output.txt"
            )
        }
    }

    var muterWithCoverageOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_with_coverage_output.txt")
        }
    }

    var muterWithTimeoutOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_timeout_output.txt")
        }
    }

    var muterEmptyStateOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_empty_state_output.txt")
        }
    }

    var muterAbortedTestingOutput: String {
        get throws {
            try contentsOfFileAsString(
                "\(rootTestDirectory)/samples/muters_aborted_testing_output.txt"
            )
        }
    }

    var muterHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_help_output.txt")
        }
    }

    var muterInitHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_init_help_output.txt")
        }
    }

    var muterRunHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_run_help_output.txt")
        }
    }

    var muterOperatorHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_operator_help_output.txt")
        }
    }

    var muterReportHelpOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_report_help_output.txt")
        }
    }

    var muterOperatorAllOutput: String {
        get throws {
            try contentsOfFileAsString("\(rootTestDirectory)/samples/muters_operator_all_output.txt")
        }
    }

    var muterLogFiles: [String] {
        get throws {
            try contentsOfDirectory(muterLogsRootPath)
                .map { muterLogsRootPath + "/" + $0 }
                .flatMap(contentsOfDirectory)
        }
    }

    var createdIOSConfiguration: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_iOS_config.yml")
        }
    }

    var createdMacOSConfiguration: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_macOS_config.yml")
        }
    }

    var createdTestPlan: Data {
        get throws {
            try contentsOfFileAsData("\(rootTestDirectory)/samples/created_muter-mappings.json")
        }
    }

    var muterLogsRootPath: String { "\(rootTestDirectory)/samples/muter_logs/" }

    func contentsOfLogFile(named fileName: String) throws -> String {
        guard let logFolder = try contentsOfDirectory(muterLogsRootPath).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: muterLogsRootPath])
        }
        return try contentsOfFileAsString(muterLogsRootPath + logFolder + "/" + fileName)
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        try FileManager
            .default
            .contentsOfDirectory(atPath: path)
            .exclude { $0.starts(with: ".") } // this filters out hidden files/folders
    }

    func contentsOfFileAsString(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let output = String(data: data, encoding: .utf8)
        else {
            throw AcceptanceTestsError.reason("File not found at \(path)")
        }

        return output
    }

    func contentsOfFileAsData(_ path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AcceptanceTestsError.reason(
                "Unable to find a valid output file from a prior run of SwiftMutator at \(path)"
            )
        }
        return data
    }
}
