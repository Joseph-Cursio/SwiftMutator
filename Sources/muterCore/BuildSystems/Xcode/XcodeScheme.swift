import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The fields of an `.xctestplan` file that name the targets it tests.
private struct XcodeTestPlanFile: Decodable {
    let testTargets: [XcodeTestPlanTarget]?
}

/// A target an `XcodeTestPlanFile` tests.
private struct XcodeTestPlanTarget: Decodable {
    let target: XcodeTestPlanTargetReference
}

/// Where an `XcodeTestPlanTarget` is: the project or package, as `container:` and its path, and its ID there.
private struct XcodeTestPlanTargetReference: Decodable {
    let containerPath: String
    let identifier: String
}

/// Reads an `.xcscheme` file's references to the targets its test action builds.
private final class SchemeReader: NSObject, XMLParserDelegate {
    var targets: [XcodeScheme.TargetReference] = []
    var testPlans: [String] = []
    var autocreatesATestPlan = false
    /// The names of the elements the parser is in, outermost first, and whether each counts: a build action entry
    /// counts when it builds for testing.
    private var path: [(name: String, counts: Bool)] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "BuildActionEntry":
            path.append((elementName, attributes["buildForTesting"] == "YES"))

        case "TestAction":
            autocreatesATestPlan = attributes["shouldAutocreateTestPlan"] == "YES"
            path.append((elementName, true))

        case "TestPlanReference":
            if let reference = attributes["reference"], isInTheTestAction {
                testPlans.append(XcodeScheme.withoutContainerPrefix(reference))
            }
            path.append((elementName, true))

        case "BuildableReference":
            let counts = path.last.map { $0.name == "BuildActionEntry" ? $0.counts : isInTheTestAction } ?? false
            if counts, let container = attributes["ReferencedContainer"],
               let identifier = attributes["BlueprintIdentifier"] {
                targets.append(.init(container: XcodeScheme.withoutContainerPrefix(container), identifier: identifier))
            }
            path.append((elementName, counts))

        default:
            path.append((elementName, true))
        }
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        _ = path.popLast()
    }

    /// Whether the parser is in the test action, where its testables, the target its tests expand the settings of,
    /// and its test plans are.
    private var isInTheTestAction: Bool {
        path.contains { $0.name == "TestAction" }
    }
}

/// What an Xcode scheme's test action builds, from its `.xcscheme` file: the targets its build action builds for
/// testing, those it tests, skipped or not, the one whose settings its tests expand, and its test plans, which name
/// the targets they test.
struct XcodeScheme: Equatable {
    /// A target a scheme or test plan names: by its ID in the project or package `container` names, a path relative to
    /// the folder that holds the workspace or project the scheme is in, empty for that folder itself.
    struct TargetReference: Hashable {
        let container: String
        let identifier: String
    }

    /// The targets the test action builds, as the scheme names them.
    var targets: [TargetReference] = []
    /// Its test plans, by their paths relative to the folder that holds the workspace or project the scheme is in.
    var testPlans: [String] = []
    /// Whether Xcode makes a test plan of the scheme's own when it names none: of every test target that depends on
    /// a target it builds, which the file doesn't list.
    var autocreatesATestPlan = false

    /// The scheme in `text`, an `.xcscheme` file's; nil if it doesn't parse.
    init?(_ text: String) {
        let reader = SchemeReader()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = reader
        guard parser.parse() else { return nil }
        targets = reader.targets
        testPlans = reader.testPlans
        autocreatesATestPlan = reader.autocreatesATestPlan
    }

    init(targets: [TargetReference], testPlans: [String] = [], autocreatesATestPlan: Bool = false) {
        self.targets = targets
        self.testPlans = testPlans
        self.autocreatesATestPlan = autocreatesATestPlan
    }

    /// The targets the test plan in `text`, an `.xctestplan` file's, tests, enabled or not; nil if it doesn't parse.
    static func targets(ofTestPlan text: String) -> [TargetReference]? {
        guard let plan = try? JSONDecoder().decode(XcodeTestPlanFile.self, from: Data(text.utf8)) else { return nil }
        return (plan.testTargets ?? []).map { testTarget in
            TargetReference(
                container: withoutContainerPrefix(testTarget.target.containerPath),
                identifier: testTarget.target.identifier
            )
        }
    }

    /// `location` without the `container:` that a scheme's and a test plan's references start with.
    static func withoutContainerPrefix(_ location: String) -> String {
        location.hasPrefix("container:") ? String(location.dropFirst("container:".count)) : location
    }
}
