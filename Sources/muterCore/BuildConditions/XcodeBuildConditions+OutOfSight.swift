import Foundation

extension XcodeBuildConditions {
    /// The settings that put a target's intermediate files, its file list among them, somewhere.
    static let buildFolderSettings: Set = [
        "OBJROOT", "SYMROOT", "BUILD_DIR", "BUILD_ROOT", "PROJECT_TEMP_DIR", "PROJECT_TEMP_ROOT",
        "CONFIGURATION_TEMP_DIR", "TARGET_TEMP_DIR", "TEMP_DIR", "TEMP_ROOT", "TEMP_FILES_DIR", "OBJECT_FILE_DIR",
        "SWIFT_RESPONSE_FILE_PATH", "SHARED_PRECOMPS_DIR", "DERIVED_DATA_DIR",
    ]

    /// What in a build file may compile a file SwiftMutator doesn't find in a list in `OBJROOT`, or with conditions
    /// `-showBuildSettings` doesn't report: in workspace settings, a build location of their own; and in a project file
    /// or build configuration file, a setting for an architecture or variant, another project, a target an external
    /// tool builds, a script that runs the compiler or another build, or a setting that moves intermediate files.
    static func mayCompileOutOfSight(_ file: BuildFile) -> Bool {
        // A workspace's projects are the caller's: it goes by the lists only where it read all their build files,
        // which this then looks at in turn.
        if file.name.hasSuffix(".xcsettings") {
            return file.text.contains("BuildLocation")
        }
        return tellTales.contains { file.text.contains($0) } || names(in: [file]).contains { name in
            buildFolderSettings.contains { name == $0 || name.hasPrefix($0 + "_") }
                || perCompileSettings.contains(name)
        }
    }

    /// Text in a build file or script that may compile Swift out of the lists' sight, or set something for one
    /// architecture or variant: by a condition on a setting, or by a reference to one, as `$(FLAGS_$(arch))`, which
    /// `-showBuildSettings` resolves with none.
    static let tellTales = [
        "[arch=", "[variant=", "(arch)", "{arch}", "(variant)", "{variant}", "PBXLegacyTarget", "wrapper.pb-project",
        "swiftc", "swift-frontend", "swift build", "xcodebuild",
    ]

    /// The settings the build sets for each compile, for an architecture or variant, that `-showBuildSettings` reports
    /// with none.
    static let perCompileSettings: Set = ["CURRENT_ARCH", "CURRENT_VARIANT", "NATIVE_ARCH", "ACTION"]

    /// How a Run Script phase names the folder of its project.
    static let projectFolderReferences = [
        "${SRCROOT}", "$SRCROOT", "$(SRCROOT)", "${PROJECT_DIR}", "$PROJECT_DIR", "$(PROJECT_DIR)",
    ]

    /// The kinds of file a Run Script phase may run.
    static let scriptExtensions = [".sh", ".bash", ".zsh", ".py", ".rb", ".pl", ".command", ".swift"]

    /// Whether a project file has a Run Script phase that runs a script SwiftMutator can't read, or that holds a tell
    /// tale: one outside the project, by a path that leaves it, starts from a variable it doesn't follow, or names no
    /// file. A script runs in the folder of the project, which `SRCROOT` and `PROJECT_DIR` name.
    static func runsAScriptThatMayCompile(_ file: BuildFile, fileManager: FileSystemManager) -> Bool {
        guard file.name == "project.pbxproj" else { return false }
        let projectFolder = file.path.deletingLastPathComponent.deletingLastPathComponent
        let scripts = file.text.split(whereSeparator: \.isNewline).filter { $0.contains("shellScript = ") }
        for script in scripts {
            if script.contains("../") || script.contains("~/") || script.contains("$HOME") {
                return true
            }
            let words = script.replacingOccurrences(of: "\\n", with: " ")
                .split { $0.isWhitespace || "\"';|&<>`".contains($0) || $0 == "\\" }
            for word in words where scriptExtensions.contains(where: word.hasSuffix) {
                var path = String(word)
                for folder in projectFolderReferences {
                    path = path.replacingOccurrences(of: folder, with: projectFolder)
                }
                if !path.hasPrefix("/") {
                    path = projectFolder + "/" + path
                }
                guard !path.contains("$"), path.hasPrefix(projectFolder + "/"),
                      let contents = fileManager.contents(atPath: path)
                else {
                    return true
                }
                let text = String(lossyUTF8: contents)
                if tellTales.contains(where: text.contains) {
                    return true
                }
            }
        }
        return false
    }

    /// The paths of the file lists under `objectRoot`, at `<project or package>.build/<configuration>/<target>.build/
    /// Objects-<variant>/<architecture>/<product>.SwiftFileList`.
    static func fileLists(under objectRoot: FilePath, fileManager: FileSystemManager) -> [FilePath] {
        func entries(of folder: FilePath, endingIn suffix: String = "") -> [FilePath] {
            ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(suffix) }
                .map { folder + "/" + $0 }
        }
        return entries(of: objectRoot, endingIn: ".build")
            .flatMap { entries(of: $0) }
            .flatMap { entries(of: $0, endingIn: ".build") }
            .flatMap { target in
                entries(of: target).filter { ($0).lastPathComponent.hasPrefix("Objects-") }
            }
            .flatMap { entries(of: $0) }
            .flatMap { entries(of: $0, endingIn: ".SwiftFileList") }
    }

    /// The paths in a file list: one a line, with a backslash before a space, a quote or a backslash in one. Nil if a
    /// line isn't an absolute path.
    static func filePaths(inFileList text: String) -> [FilePath]? {
        var paths: [FilePath] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var path = ""
            var escaped = false
            for character in line {
                if escaped || character != "\\" {
                    path.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            guard path.hasPrefix("/"), !escaped else { return nil }
            paths.append(path)
        }
        return paths
    }
}
