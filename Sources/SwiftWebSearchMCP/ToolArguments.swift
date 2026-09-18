import Foundation
import MCP
import WebSearchCore

/// A validated view over MCP tool arguments.
///
/// Errors are thrown as `ArgumentError` and converted into `isError` tool results so
/// a model gets an actionable message rather than a protocol-level failure.
public struct ToolArguments: Sendable {
    private let raw: [String: Value]

    public init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    public struct ArgumentError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public func string(_ name: String) throws -> String? {
        guard let value = raw[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ArgumentError("`\(name)` must be a string")
        }
        return text
    }

    public func requiredString(_ name: String) throws -> String {
        guard
            let value = try string(name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            throw ArgumentError("`\(name)` is required and must be a non-empty string")
        }
        return value
    }

    public func int(_ name: String) throws -> Int? {
        guard let value = raw[name], !value.isNull else { return nil }
        if let integer = value.intValue { return integer }
        // Tolerate a numeric string: some clients serialize numbers as strings.
        if let text = value.stringValue, let integer = Int(text) { return integer }
        throw ArgumentError("`\(name)` must be an integer")
    }

    public func stringArray(_ name: String, maxItems: Int) throws -> [String] {
        guard let value = raw[name], !value.isNull else { return [] }
        guard let elements = value.arrayValue else {
            throw ArgumentError("`\(name)` must be an array of strings")
        }
        guard elements.count <= maxItems else {
            throw ArgumentError("`\(name)` accepts at most \(maxItems) entries")
        }
        var result: [String] = []
        for element in elements {
            guard let text = element.stringValue else {
                throw ArgumentError("`\(name)` must contain only strings")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    public func enumValue<T: RawRepresentable>(
        _ name: String,
        as type: T.Type = T.self,
        default fallback: T
    ) throws -> T where T.RawValue == String {
        guard let text = try string(name) else { return fallback }
        guard let parsed = T(rawValue: text.lowercased()) else {
            throw ArgumentError("`\(name)` must be one of the documented values")
        }
        return parsed
    }
}

// MARK: - Response formatting
