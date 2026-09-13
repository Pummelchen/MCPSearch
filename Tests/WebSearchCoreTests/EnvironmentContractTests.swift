import Foundation
import XCTest

@testable import WebSearchCore

/// The environment-variable contract between the server and everything that configures it.
///
/// `AppConfiguration.Key` is the server's source of truth for these names, but `example.env`, the
/// Python harnesses, `deploy/` and CI all spell them as plain strings. A rename therefore breaks a
/// consumer silently: the server keeps running and simply stops seeing the setting. Nothing
/// connected the two ends (ledger A12), so these tests do.
final class EnvironmentContractTests: XCTestCase {

    /// Variables that are deliberately not server settings.
    ///
    /// Every entry carries a reason, and `testDeclaredExceptionsAreStillUsed` fails when one is no
    /// longer needed, so this list cannot quietly become a place where drift hides.
    private static let nonServerVariables: [String: String] = [
        "SEARCH_LIVE_TESTS":
            "read by the test suite to opt into live provider calls, never by the server"
    ]

    // MARK: - Fixtures

    /// The package root, from this file's own path: `…/Tests/WebSearchCoreTests/<file>`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every file that configures the server or the deployment.
    ///
    /// The scope is the finding's: the example file, the Python harnesses, `deploy/` and the
    /// workflows. Tests and documentation are deliberately outside it — they *talk about* these
    /// names (including names that were removed on purpose) rather than reading them.
    private func configurationFiles() throws -> [URL] {
        var files: [URL] = [packageRoot.appendingPathComponent("example.env")]
        for directory in ["scripts", "deploy", ".github/workflows"] {
            let base = packageRoot.appendingPathComponent(directory)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: base,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
            else { continue }
            for case let url as URL in enumerator {
                let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
                if isFile == true { files.append(url) }
            }
        }
        return files
    }

    /// The capture group 1 of every match of `pattern` in the file.
    private func names(
        in url: URL,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) throws -> Set<String> {
        let text = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let group = Range(match.range(at: 1), in: text) {
                found.insert(String(text[group]))
            }
        }
        return found
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
    }

    // MARK: - The contract

    /// Every setting the server reads must be documented where operators look for it.
    func testEveryConfigurationKeyIsDocumentedInTheExampleFile() throws {
        let documented = try names(
            in: packageRoot.appendingPathComponent("example.env"),
            // Both `NAME=` and the `# export NAME=` form the file uses for the config-file
            // pointer are assignments an operator can copy.
            // `^` must mean "start of line" here, so the anchors option is not optional.
            pattern: #"^\s*#?\s*(?:export\s+)?([A-Z][A-Z0-9_]*)="#,
            options: [.anchorsMatchLines]
        )
        let missing = AppConfiguration.Key.allCases.map(\.rawValue)
            .filter { !documented.contains($0) }
        XCTAssertEqual(
            missing,
            [],
            "example.env must document: \(missing.joined(separator: ", "))"
        )
    }

    /// Two cases that share a raw value would make one of them unreachable.
    func testConfigurationKeysHaveUniqueNames() {
        let raw = AppConfiguration.Key.allCases.map(\.rawValue)
        XCTAssertEqual(raw.count, Set(raw).count, "two AppConfiguration.Key cases share a raw value")
    }

    /// Every variable the scripts, the provenance files and CI name must be a setting the server
    /// actually reads, so a rename cannot leave a consumer pointing at nothing.
    func testEveryVariableTheScriptsAndDeploymentUseIsAConfigurationKey() throws {
        let keys = Set(AppConfiguration.Key.allCases.map(\.rawValue))
        var unknown: [String: [String]] = [:]
        for file in try configurationFiles() {
            let literals = try names(
                in: file,
                pattern: #"\b(SEARCH_[A-Z0-9_]+|(?:[A-Z][A-Z0-9_]*_)?API_KEY)\b"#
            )
            for literal in literals.sorted()
            where !keys.contains(literal) && Self.nonServerVariables[literal] == nil {
                unknown[literal, default: []].append(relativePath(file))
            }
        }
        XCTAssertEqual(
            unknown,
            [:],
            "these variables are named outside the server but are not AppConfiguration.Key cases: "
                + "\(unknown)"
        )
    }

    /// An exception that is no longer used must be deleted, or the list becomes a hiding place.
    func testDeclaredExceptionsAreStillUsed() throws {
        let contents = try configurationFiles()
            .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
            .joined(separator: "\n")
        for name in Self.nonServerVariables.keys {
            XCTAssertTrue(
                contents.contains(name),
                "\(name) is declared as a non-server variable but nothing uses it any more"
            )
        }
    }
}
