import Foundation
import XCTest

/// Cross-client schema compatibility tests.
///
/// A tool schema that one mainstream consumer rejects can fail the entire request, so
/// the advertised schemas are held to the intersection of what the strictest consumers
/// require. The rules below are not stylistic preferences; each is a verified
/// rejection or requirement from a real client:
///
/// | Rule | Why |
/// | --- | --- |
/// | `additionalProperties: false` on every object | OpenAI **requires** it under strict mode. The most common real MCP-to-OpenAI failure is a *missing* one. |
/// | every declared property also in `required` | OpenAI strict mode requires it. Optionality is a nullable type instead. |
/// | nullable unions (`["string","null"]`) for optionals | The documented strict-mode idiom; supported by OpenAI and accepted by Anthropic. |
/// | no `format` | OpenAI allows only nine formats and rejects `format: "uri"` outright. |
/// | no `default` | Not a supported keyword; rejected outright by some OpenAI-compatible deployments. |
/// | no `oneOf` / `allOf` / `not` | Unsupported; `anyOf` is the permitted combinator. |
/// | every object declares `properties` | An object schema without it is rejected. |
/// | every object declares `required` | An absent key must not be read as "the empty set"; the declared set is the contract. |
/// | every array declares `items` | Required for a well-formed schema. |
/// | root is a closed object, never a union | Non-object roots are rejected. |
/// | tool names at most 64 characters | Documented limit across clients. |
///
/// Tools are reached over stdio because the schemas are only visible through the
/// server's `tools/list` response, which is also what a client actually sees.
final class SchemaCompatibilityTests: XCTestCase {

    // MARK: - Server harness

    private final class Server {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        private var buffer = Data()

        init(binary: URL) {
            process.executableURL = binary
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()
            // Hermetic: no provider credentials can influence the tool list.
            process.environment = ServerTestSupport.childEnvironment(base: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            ])
        }

        func start() throws { try process.run() }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(UInt8(ascii: "\n"))
            stdin.fileHandleForWriting.write(data)
        }

        func readResponse(id: Int, timeout: TimeInterval = 20) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard !line.isEmpty else { continue }
                    if let object = try JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any],
                        (object["id"] as? Int) == id
                    {
                        return object
                    }
                    continue
                }
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { throw Failure.unexpectedExit }
                buffer.append(chunk)
            }
            throw Failure.timeout
        }

        func stop() {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        enum Failure: Error { case timeout, unexpectedExit }
    }

    /// Fetch `tools/list` from a freshly started server.
    private func advertisedTools() throws -> [[String: Any]] {
        let binary = try ServerTestSupport.binaryURL()

        let server = Server(binary: binary)
        try server.start()
        defer { server.stop() }

        try server.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "schema-audit", "version": "1.0.0"],
            ],
        ])
        _ = try server.readResponse(id: 1)
        try server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try server.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])

        let response = try server.readResponse(id: 2)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["tools"] as? [[String: Any]])
    }

    // MARK: - Recursive validation

    /// Keywords that strict consumers reject outright.
    private static let bannedKeywords = [
        "format", "default", "oneOf", "allOf", "not",
        "patternProperties", "uniqueItems", "contains", "if", "then", "else",
        "propertyNames", "unevaluatedProperties", "unevaluatedItems",
    ]

    /// Walk a schema and collect every cross-client violation.
    private func violations(
        in node: Any,
        path: String,
        into found: inout [String]
    ) {
        if let object = node as? [String: Any] {
            for keyword in SchemaCompatibilityTests.bannedKeywords where object[keyword] != nil {
                found.append("\(path): banned keyword `\(keyword)`")
            }

            // A `type` may be a string or an array of strings (nullable unions).
            if let type = object["type"] as? String, type == "object" {
                if object["properties"] == nil {
                    found.append("\(path): object schema without `properties`")
                }
                if object["additionalProperties"] as? Bool != false {
                    found.append("\(path): `additionalProperties` must be false")
                }
                // An absent `required` must not be read as "the empty set": that made a
                // zero-argument object indistinguishable from one that simply forgot the key.
                // The contract is about the declared keyword, so every object schema must
                // carry it, even when there is nothing to require (ledger B112).
                if object["required"] == nil {
                    found.append("\(path): object schema without `required`")
                }
                let properties = Set((object["properties"] as? [String: Any])?.keys ?? [:].keys)
                let required = Set(object["required"] as? [String] ?? [])
                if properties != required {
                    let missing = properties.subtracting(required).sorted()
                    let extra = required.subtracting(properties).sorted()
                    found.append(
                        "\(path): properties/required mismatch "
                            + "(not required: \(missing), required but undeclared: \(extra))"
                    )
                }
            }

            if let type = object["type"] as? String, type == "array", object["items"] == nil {
                found.append("\(path): array schema without `items`")
            }

            for (key, value) in object {
                violations(in: value, path: "\(path).\(key)", into: &found)
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() {
                violations(in: value, path: "\(path)[\(index)]", into: &found)
            }
        }
    }

    // MARK: - Tests

    /// Every advertised schema, input and output, must satisfy all client rules.
    func testAllAdvertisedSchemasSatisfyCrossClientRules() throws {
        let tools = try advertisedTools()
        XCTAssertFalse(tools.isEmpty)

        var allViolations: [String] = []
        for tool in tools {
            let name = tool["name"] as? String ?? "?"

            for (label, key) in [("inputSchema", "inputSchema"), ("outputSchema", "outputSchema")] {
                guard let schema = tool[key] else { continue }
                var found: [String] = []
                violations(in: schema, path: "\(name).\(label)", into: &found)
                allViolations.append(contentsOf: found)
            }
        }

        XCTAssertTrue(
            allViolations.isEmpty,
            "schemas violate cross-client rules:\n  "
                + allViolations.joined(separator: "\n  ")
        )
    }

    /// The root of every schema must be a plain closed object.
    func testRootIsAlwaysAClosedObject() throws {
        for tool in try advertisedTools() {
            let name = tool["name"] as? String ?? "?"
            for key in ["inputSchema", "outputSchema"] {
                guard let schema = tool[key] as? [String: Any] else { continue }
                XCTAssertEqual(
                    schema["type"] as? String, "object",
                    "\(name).\(key) root must be an object, not a union"
                )
                XCTAssertEqual(
                    schema["additionalProperties"] as? Bool, false,
                    "\(name).\(key) root must be closed"
                )
                XCTAssertNotNil(
                    schema["properties"],
                    "\(name).\(key) root must declare properties, even if empty"
                )
                for combinator in ["anyOf", "oneOf", "allOf", "enum", "not"] {
                    XCTAssertNil(
                        schema[combinator],
                        "\(name).\(key) must not use a root-level `\(combinator)`"
                    )
                }
            }
        }
    }

    /// Tool names must respect the documented 64-character limit.
    func testToolNamesRespectLengthLimit() throws {
        for tool in try advertisedTools() {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertLessThanOrEqual(name.count, 64, "tool name too long: \(name)")
            XCTAssertFalse(name.isEmpty)
            // Names must be safe identifiers across clients.
            XCTAssertTrue(
                name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" },
                "tool name has characters some clients reject: \(name)"
            )
        }
    }

    /// Property names must respect the per-client length and character rules.
    func testPropertyNamesArePortable() throws {
        var names: [String] = []
        func collect(_ node: Any) {
            if let object = node as? [String: Any] {
                if let properties = object["properties"] as? [String: Any] {
                    names.append(contentsOf: properties.keys)
                }
                for value in object.values { collect(value) }
            } else if let array = node as? [Any] {
                for value in array { collect(value) }
            }
        }
        for tool in try advertisedTools() {
            if let schema = tool["inputSchema"] { collect(schema) }
            if let schema = tool["outputSchema"] { collect(schema) }
        }

        XCTAssertFalse(names.isEmpty)
        for name in Set(names) {
            XCTAssertLessThanOrEqual(name.count, 64, "property name too long: \(name)")
            XCTAssertGreaterThan(name.count, 0)
            XCTAssertTrue(
                name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" },
                "property name has characters some clients reject: \(name)"
            )
        }
    }

    /// Schemas declare `additionalProperties: false`, and the server must therefore not
    /// depend on any extra argument to work.
    func testToolsAreUsableWithNoOptionalArguments() throws {
        let tools = try advertisedTools()
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let required = schema["required"] as? [String] ?? []
            let properties = schema["properties"] as? [String: Any] ?? [:]

            // Because every property is declared required, a client must be able to
            // send null for the nullable ones. Verify each required-but-nullable
            // property actually allows null, otherwise a client could not omit it.
            for key in required {
                guard let property = properties[key] as? [String: Any] else { continue }
                let mutable = property["type"] as? [String] ?? []
                if key == "query" || key == "url" { continue }  // genuinely mandatory
                XCTAssertTrue(
                    mutable.contains("null"),
                    "\(name).\(key) is required but not nullable, so it cannot be omitted"
                )
            }
        }
    }

    /// The descriptions must carry the defaults, since `default` is not a usable
    /// keyword for strict consumers.
    func testDefaultsAreDocumentedInDescriptions() throws {
        let tools = try advertisedTools()
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "web_search" })
        let schema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        for (key, expected) in [
            ("max_results", "8"), ("recency", "any"), ("provider", "auto"), ("mode", "balanced"),
        ] {
            let property = try XCTUnwrap(properties[key] as? [String: Any], key)
            let description = try XCTUnwrap(property["description"] as? String, key)
            XCTAssertTrue(
                description.contains(expected),
                "\(key) description must document its default (\(expected)): \(description)"
            )
        }
    }
}
