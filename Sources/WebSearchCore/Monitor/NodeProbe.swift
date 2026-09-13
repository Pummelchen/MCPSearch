import Foundation

/// Probes one SearXNG instance and reports what it can actually do.
///
/// The probe asks for JSON directly rather than going through the MCP server, because
/// the question a monitor answers is "is this instance healthy", and a 403 from a
/// misconfigured instance must not be mistaken for a network outage.
public struct NodeProbe: Sendable {
    public struct Target: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var baseURL: URL
        /// True for the instance on the machine running the monitor.
        public var isLocal: Bool

        public init(name: String, baseURL: URL, isLocal: Bool) {
            self.name = name
            self.baseURL = baseURL
            self.isLocal = isLocal
        }
    }

    public struct Result: Sendable {
        public var state: NodeStatus.State
        public var latencyMilliseconds: Int?
        public var resultCount: Int
        public var engines: [String]
        public var unavailableEngines: [String]
        public var error: String?
    }

    public let http: any HTTPClient
    /// A cheap query, deliberately stable so latency is comparable between refreshes.
    public let query: String

    public init(http: any HTTPClient, query: String = "swift concurrency") {
        self.http = http
        self.query = query
    }

    public func probe(_ target: Target) async -> Result {
        let started = DispatchTime.now().uptimeNanoseconds

        guard
            var components = URLComponents(
                url: target.baseURL.appendingPathComponent("search"),
                resolvingAgainstBaseURL: false
            )
        else {
            return Result(
                state: .down,
                latencyMilliseconds: nil,
                resultCount: 0,
                engines: [],
                unavailableEngines: [],
                error: "invalid URL"
            )
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            return Result(
                state: .down,
                latencyMilliseconds: nil,
                resultCount: 0,
                engines: [],
                unavailableEngines: [],
                error: "invalid URL"
            )
        }

        do {
            let response = try await http.send(
                HTTPRequest.get(url, headers: ["Accept": "application/json"], label: "node.probe"),
                maxBytes: 4 * 1024 * 1024
            )
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)

            if response.statusCode == 403 {
                // The instance is running but its JSON API is disabled. Reporting this as
                // "down" would send an operator hunting for a network fault.
                return Result(
                    state: .degraded,
                    latencyMilliseconds: elapsed,
                    resultCount: 0,
                    engines: [],
                    unavailableEngines: [],
                    error: "JSON disabled (add `json` to search.formats)"
                )
            }
            guard response.isSuccess else {
                return Result(
                    state: .degraded,
                    latencyMilliseconds: elapsed,
                    resultCount: 0,
                    engines: [],
                    unavailableEngines: [],
                    error: "HTTP \(response.statusCode)"
                )
            }

            let payload = try JSONCoding.decoder().decode(SearXNGProbeResponse.self, from: response.body)

            var engines: Set<String> = []
            for item in payload.results {
                if let engine = item.engine { engines.insert(engine) }
                for engine in item.engines ?? [] { engines.insert(engine) }
            }

            let unavailable = (payload.unresponsiveEngines ?? []).compactMap { entry -> String? in
                guard entry.count >= 2 else { return nil }
                return "\(entry[0]): \(entry[1])"
            }

            let state: NodeStatus.State = payload.results.isEmpty ? .degraded : .up
            return Result(
                state: state,
                latencyMilliseconds: elapsed,
                resultCount: payload.results.count,
                engines: engines.sorted(),
                unavailableEngines: unavailable,
                error: payload.results.isEmpty ? "no results returned" : nil
            )
        } catch let error as SearchError {
            return Result(
                state: .down,
                latencyMilliseconds: nil,
                resultCount: 0,
                engines: [],
                unavailableEngines: [],
                error: error.safeDescription
            )
        } catch {
            return Result(
                state: .down,
                latencyMilliseconds: nil,
                resultCount: 0,
                engines: [],
                unavailableEngines: [],
                error: "unreachable"
            )
        }
    }

    /// The subset of the SearXNG JSON response the monitor needs.
    private struct SearXNGProbeResponse: Decodable {
        let results: [Item]
        let unresponsiveEngines: [[String]]?

        /// SearXNG writes `unresponsive_engines`. Without this mapping the monitor's
        /// unavailable-engine column was always empty against a live instance, even though
        /// `SearXNGProvider` maps the same key explicitly.
        enum CodingKeys: String, CodingKey {
            case results
            case unresponsiveEngines = "unresponsive_engines"
        }

        struct Item: Decodable {
            let engine: String?
            let engines: [String]?
        }
    }
}
