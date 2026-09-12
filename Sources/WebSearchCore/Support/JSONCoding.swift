import Foundation

/// Shared JSON coding helpers.
///
/// Providers each get their own `JSONDecoder` configuration through these helpers
/// so that decoding never depends on a global mutable decoder.
public enum JSONCoding {
    /// Decoder tolerant of the date formats search vendors actually emit.
    ///
    /// Tried in order: RFC 3339 with fractional seconds, RFC 3339 without,
    /// `yyyy-MM-dd`, and plain epoch seconds.
    public static func decoder(
        keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
    ) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keyDecodingStrategy
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let number = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: number)
            }

            let raw = try container.decode(String.self)
            if let date = date(from: raw) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return decoder
    }

    /// A configured encoder for outbound request bodies.
    public static func encoder(
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys,
        prettyPrinted: Bool = false
    ) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = keyEncodingStrategy
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return encoder
    }

    /// Parse the handful of date spellings seen in the wild.
    public static func date(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Double(trimmed) {
            return Date(timeIntervalSince1970: seconds)
        }

        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime]),
            ISO8601DateFormatter.Options([.withFullDate]),
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return date }
        }

        // `yyyy-MM-dd HH:mm:ss` and similar space-separated forms.
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }

        // RFC 1123 / RFC 822 style, which Tavily uses for `published_date`
        // (`Tue, 11 Mar 2025 17:00:00 GMT`).
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss ZZZ",
            "EEE, dd MMM yyyy HH:mm:ss",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }

        return nil
    }
}

extension Data {
    /// Decode, mapping any failure onto a provider-appropriate error.
    func decodeJSON<T: Decodable>(
        _ type: T.Type,
        provider: ProviderID,
        using decoder: JSONDecoder
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: self)
        } catch {
            throw SearchError.malformedResponse(provider)
        }
    }
}
