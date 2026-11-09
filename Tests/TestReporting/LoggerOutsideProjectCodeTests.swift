import Foundation
@testable import muterCore
import XCTest

/// What the logger says of the code the build uses from outside the project, which gets no mutants.
final class LoggerOutsideProjectCodeTests: MuterTestCase {
    private let sut = Logger()

    // Code the build uses from outside the project: five by path, the rest counted, and how to mutate it too.
    func test_codeOutsideTheProjectBuilt_namesThePaths_andSaysHowToMutateThem() {
        sut.codeOutsideTheProjectBuilt(["../Shared"])
        sut.codeOutsideTheProjectBuilt((1 ... 7).map { "../Package\($0)" })

        let heading = "ℹ️ Your project's build uses code outside its folder, which SwiftMutator doesn't copy, so it is "
            + "built from where it is and gets no mutants:"
        let howTo = "Mutants are made only in the folder SwiftMutator runs in. To mutate that code too, run it from a "
            + "folder that holds both, such as your repository's root, with \("arguments".bold) naming the project "
            + "there, or move the code into the project."
        XCTAssertEqual(printer.linesPassed, [
            [heading, "  ../Shared", howTo].joined(separator: "\n"),
            ([heading] + (1 ... 5).map { "  ../Package\($0)" } + ["  … and 2 more", howTo]).joined(separator: "\n"),
        ])
    }
}
