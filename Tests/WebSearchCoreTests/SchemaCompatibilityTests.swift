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
/// | nullable types admit null in `enum` too | `type` and `enum` are conjunctive, so an `enum` that omits null makes the advertised nullable union an illegal value; a strict client filling every `required` slot cannot say "use the default". |
/// | mirrored tools agree property by property | `web_answer` advertises the same discovery arguments as `web_search`; a constraint that reaches only one of them is a client-visible divergence. |
/// | root is a closed object, never a union | Non-object roots are rejected. |
/// | tool names at most 64 characters | Documented limit across clients. |
///
/// Tools are reached over stdio because the schemas are only visible through the
/// server's `tools/list` response, which is also what a client actually sees.
final class SchemaCompatibilityTests: XCTestCase {

    // MARK: - Server harness

    /// The one subprocess harness, shared with every other stdio test file.
    ///
    /// This file used to carry its own copy, which had drifted further than the others: its
    /// `Failure` enum was `case timeout, unexpectedExit` with no stderr payload, and the
    /// `Pipe()` it assigned to `standardError` was never read, so an early exit reported the
    /// bare words `unexpectedExit` and no diagnostic at all.
    private typealias Server = ServerProcess

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

    /// A canonical form for comparing two schema fragments.
    ///
    /// `JSONSerialization` preserves array order, which matters for `enum`: the
    /// advertised order is part of what a client shows a model, so two lists with the
    /// same members in a different order are a drift worth reporting.
    private func canonical(_ value: Any?) -> String {
        guard
            let value,
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]
            )
        else {
            return "<none>"
        }
        return String(bytes: data, encoding: .utf8) ?? "<none>"
    }

    /// Walk a schema and collect every cross-client violation.
    ///
    /// `mirror` is the schema of the tool this one documents itself as a mirror of, when
    /// there is one. `web_answer` advertises the same discovery arguments as
    /// `web_search`, so the two are compared property by property: a constraint can
    /// otherwise reach one tool and not the other, which is how `web_answer.provider`
    /// lost its `enum` with every structural rule still green.
    private func violations(
        in node: Any,
        path: String,
        mirror: [String: Any]? = nil,
        into found: inout [String]
    ) {
        if let object = node as? [String: Any] {
            for keyword in SchemaCompatibilityTests.bannedKeywords where object[keyword] != nil {
                found.append("\(path): banned keyword `\(keyword)`")
            }

            // Compare the shared discovery arguments, keyed by the property itself so
            // the result does not depend on either schema's declaration order. Only
            // the keywords that constrain a value are compared: prose may legitimately
            // differ because the two tools describe what they do with it, but a
            // constraint may not. `provider` is held to the whole property, because
            // the closed set of ids is the contract a client discovers.
            if let mirror, let properties = object["properties"] as? [String: Any],
                let mirrored = mirror["properties"] as? [String: Any]
            {
                let mirroredKeys = Set(mirrored.keys).subtracting(["query"])
                let declaredKeys = Set(properties.keys).subtracting(["query"])
                if mirroredKeys != declaredKeys {
                    found.append(
                        "\(path): discovery arguments differ from the mirrored schema "
                            + "(missing: \(mirroredKeys.subtracting(declaredKeys).sorted()), "
                            + "extra: \(declaredKeys.subtracting(mirroredKeys).sorted()))"
                    )
                }
                for key in declaredKeys.intersection(mirroredKeys) {
                    guard
                        let declared = properties[key] as? [String: Any],
                        let expected = mirrored[key] as? [String: Any]
                    else {
                        found.append("\(path): discovery argument `\(key)` is not an object")
                        continue
                    }
                    if key == "provider" {
                        if canonical(declared) != canonical(expected) {
                            found.append(
                                "\(path): discovery argument `provider` differs from the schema "
                                    + "this tool mirrors, so a client cannot discover the ids "
                                    + "the server accepts"
                            )
                        }
                        continue
                    }
                    let base = Set(declared.keys).union(expected.keys).subtracting(["description"])
                    for field in base.sorted() where canonical(declared[field]) != canonical(expected[field]) {
                        found.append(
                            "\(path): discovery argument `\(key).\(field)` differs from the "
                                + "mirrored schema"
                        )
                    }
                }
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
                // carry it, even when there is nothing to require.
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

            // In JSON Schema `type` and `enum` are conjunctive, so a nullable union whose
            // `enum` omits null advertises a value that no strict validator accepts: the
            // value satisfies `type` and violates `enum`. Because every property is also
            // `required`, a client that fills every slot must send null to mean "use the
            // default", and such a client could not legally express it.
            if let properties = object["properties"] as? [String: Any] {
                for key in properties.keys.sorted() {
                    guard
                        let property = properties[key] as? [String: Any],
                        let types = property["type"] as? [String],
                        types.contains("null"),
                        let values = property["enum"] as? [Any]
                    else { continue }
                    if !values.contains(where: { $0 is NSNull }) {
                        found.append(
                            "\(path).\(key): `type` admits null but `enum` does not, so the "
                                + "nullable union the schema advertises is not a legal value"
                        )
                    }
                }
            }

            for (key, value) in object {
                let nested = (mirror?["properties"] as? [String: Any])?[key]
                violations(in: value, path: "\(path).\(key)", mirror: nested as? [String: Any], into: &found)
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
        // `web_answer` declares itself a mirror of `web_search`'s discovery arguments,
        // so its input schema is walked against web_search's as the baseline.
        let searchInput =
            tools.first { $0["name"] as? String == "web_search" }?["inputSchema"]
            as? [String: Any]
        for tool in tools {
            let name = tool["name"] as? String ?? "?"

            for (label, key) in [("inputSchema", "inputSchema"), ("outputSchema", "outputSchema")] {
                guard let schema = tool[key] else { continue }
                let mirror = key == "inputSchema" && name == "web_answer" ? searchInput : nil
                var found: [String] = []
                violations(in: schema, path: "\(name).\(label)", mirror: mirror, into: &found)
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
                // `type` and `enum` are conjunctive, so a value that satisfies only one
                // of them is not legal. An enum that names the choices without null
                // rejects the very null this schema is built around.
                if let values = property["enum"] as? [Any] {
                    XCTAssertTrue(
                        values.contains { $0 is NSNull },
                        "\(name).\(key) admits null in `type` but its `enum` does not, "
                            + "so a strict client cannot fill this required slot"
                    )
                }
            }
        }
    }

    /// Every argument a strict client may need to send as null must accept null, and an
    /// `enum` must admit it.
    ///
    /// `type` and `enum` are conjunctive in JSON Schema, so an `enum` that lists the
    /// choices without null makes the advertised nullable union an invalid value. Since
    /// every property is also `required`, a client that must fill every slot could not
    /// legally say "use the default" for `recency`, `provider` or `mode`.
    /// The recursive keyword check in `violations` covers the whole advertised surface;
    /// this test states the input-schema contract for both search tools directly, so the
    /// failure names the argument a caller cannot express.
    func testOptionalSearchArgumentsAdmitNull() throws {
        for tool in try advertisedTools() {
            let name = tool["name"] as? String ?? "?"
            guard name == "web_search" || name == "web_answer" else { continue }
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

            for key in ["recency", "provider", "mode"] {
                let property = try XCTUnwrap(properties[key] as? [String: Any], "\(name).\(key)")
                XCTAssertTrue(
                    (property["type"] as? [String] ?? []).contains("null"),
                    "\(name).\(key) must be declared nullable"
                )
                let values = try XCTUnwrap(property["enum"] as? [Any], "\(name).\(key) enum")
                XCTAssertTrue(
                    values.contains { $0 is NSNull },
                    "\(name).\(key) advertises a nullable union but its enum rejects null, "
                        + "so no strict client can fill this required slot with the default"
                )
            }
        }
    }

    /// The descriptions must carry the defaults, since `default` is not a usable
    /// keyword for strict consumers.
    func testDefaultsAreDocumentedInDescriptions() throws {
        let tools = try advertisedTools()
        // Both search tools: the parity walk deliberately exempts `description`, so a copy
        // of the schema whose prose stopped documenting a default would pass it. The
        // assertion used to read `web_search` only, which left `web_answer`'s copy
        // unguarded.
        for name in ["web_search", "web_answer"] {
            let tool = try XCTUnwrap(
                tools.first { $0["name"] as? String == name },
                "\(name) is not advertised"
            )
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

            for (key, expected) in [
                ("max_results", "8"), ("recency", "any"), ("provider", "auto"),
                ("mode", "balanced"),
            ] {
                let property = try XCTUnwrap(properties[key] as? [String: Any], "\(name).\(key)")
                let description = try XCTUnwrap(
                    property["description"] as? String,
                    "\(name).\(key)"
                )
                XCTAssertTrue(
                    description.contains(expected),
                    "\(name).\(key) description must document its default (\(expected)): "
                        + description
                )
            }
        }
    }

    /// `provider` must advertise the closed set of ids the runtime parser accepts.
    ///
    /// The list is derived from `ProviderID.allCases` in the schema, so this pins the
    /// public contract down independently of that derivation: both tools must offer
    /// every id, and a value that no longer parses must not survive in either. A
    /// spelling-only assumption is what let `web_answer.provider` lose its `enum`
    /// without any structural rule noticing.
    func testProviderEnumListsTheAcceptedProviderIDs() throws {
        // `auto` is not a `ProviderID`: the parsers translate it to "let the
        // orchestrator choose" before a provider is resolved.
        let accepted: Set<String> = [
            "auto", "tavily", "brave", "mojeek", "exa", "searxng",
            "open_web_search", "duckduckgo", "startpage", "parallel",
        ]
        let tools = try advertisedTools()
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "web_search" })
        let searchSchema = try XCTUnwrap(search["inputSchema"] as? [String: Any])
        let searchProperties = try XCTUnwrap(searchSchema["properties"] as? [String: Any])

        for tool in tools where tool["name"] as? String == "web_search" || tool["name"] as? String == "web_answer" {
            let name = try XCTUnwrap(tool["name"] as? String)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let provider = try XCTUnwrap(properties["provider"] as? [String: Any])
            // The list also carries `null`, because the property is a nullable union;
            // this test is about the ids a client may send.
            let listed = Set(
                (provider["enum"] as? [Any] ?? []).compactMap { $0 as? String }.map {
                    $0.lowercased()
                }
            )

            XCTAssertEqual(
                listed, accepted,
                "\(name).provider must advertise exactly the parser's accepted ids "
                    + "(missing: \(accepted.subtracting(listed).sorted()), "
                    + "unexpected: \(listed.subtracting(accepted).sorted()))"
            )
            XCTAssertEqual(
                provider["description"] as? String,
                searchProperties["provider"].flatMap { ($0 as? [String: Any])?["description"] as? String },
                "\(name).provider must document the same default as `web_search`"
            )
        }
    }
}
