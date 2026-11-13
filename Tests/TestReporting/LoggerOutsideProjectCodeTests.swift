@testable import muterCore
import XCTest

/// What the logger says of the code the build uses from outside the project, which gets no mutants, and of the code in
/// it that the copy builds from the project.
final class LoggerOutsideProjectCodeTests: MuterTestCase {
    private let sut = Logger()

    // Code the build uses from outside the project: five by path, the rest counted, and how to mutate it too.
    func test_codeOutsideTheProjectBuilt_namesThePaths_andSaysHowToMutateThem() {
        sut.codeOutsideTheProjectBuilt(["../Shared"])
        sut.codeOutsideTheProjectBuilt((1 ... 5).map { "../Package\($0)" })
        sut.codeOutsideTheProjectBuilt((1 ... 7).map { "../Package\($0)" })

        let heading = "ℹ️ Your project's build uses code outside its folder, which SwiftMutator doesn't copy, so it is "
            + "built from where it is and gets no mutants:"
        let howTo = "Mutants are made only in the folder SwiftMutator runs in. To mutate that code too, run "
            + "SwiftMutator from a folder that holds both, such as your repository's root, with \("arguments".bold) "
            + "naming the project there, or move the code into the project."
        let five = (1 ... 5).map { "  ../Package\($0)" }
        XCTAssertEqual(printer.linesPassed, [
            [heading, "  ../Shared", howTo].joined(separator: "\n"),
            ([heading] + five + [howTo]).joined(separator: "\n"),
            ([heading] + five + ["  … and 2 more", howTo]).joined(separator: "\n"),
        ])
    }

    // Code in the project that the copy builds from the project: five by path, the rest counted, and how to fix it.
    func test_projectCodeNamedByAbsolutePath_namesThePaths_andSaysHowToFixThem() {
        sut.projectCodeNamedByAbsolutePath(["App.xcodeproj"])
        sut.projectCodeNamedByAbsolutePath((1 ... 6).map { "Packages/Package\($0)" })

        let heading = "⚠️ Your project names code in its own folder by an absolute path, which SwiftMutator's copy "
            + "names too, so the copy builds that code from your project, unmutated, and every mutant in it survives:"
        let howTo = "Name it by a relative path in your workspace or manifest instead, so that the copy builds its own."
        XCTAssertEqual(printer.linesPassed, [
            [heading, "  App.xcodeproj", howTo].joined(separator: "\n"),
            ([heading] + (1 ... 5).map { "  Packages/Package\($0)" } + ["  … and 1 more", howTo])
                .joined(separator: "\n"),
        ])
    }
}
