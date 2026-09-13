import CryptoKit
import Foundation

/// In-memory search cache.
///
/// Only *successful, normalized* responses are cached. Authentication and
/// configuration failures are never cached, because a fixed key should take effect
/// immediately. Page content fetched by `web_open` is not cached at all.
public actor SearchCache {
    public struct Key: Sendable, Hashable {
        public let digest: String

        /// Build a key from everything that meaningfully changes the answer.
        ///
        /// Provider *set* is part of the key: a `fast` Tavily answer and a `thorough`
        /// fused answer are different products and must not alias.
        public init(request: SearchRequest, providers: [ProviderID]) {
            let providerList = providers.map(\.rawValue).sorted().joined(separator: ",")
            let includeList = request.includeDomains.map { $0.lowercased() }.sorted()
                .joined(separator: ",")
            let excludeList = request.excludeDomains.map { $0.lowercased() }.sorted()
                .joined(separator: ",")
            let components = [
                request.normalizedQuery.lowercased(),
                "n=\(request.maxResults)",
                "recency=\(request.recency.rawValue)",
                "mode=\(request.mode.rawValue)",
                "inc=\(includeList)",
                "exc=\(excludeList)",
                "locale=\(request.locale?.identifier ?? "")",
                "providers=\(providerList)",
            ]
            self.digest = SearchCache.sha256(components.joined(separator: "\u{1F}"))
        }

        /// Explicit digest, for tests.
        public init(digest: String) {
            self.digest = digest
        }
    }

    private struct Entry {
        let response: SearchResponse
        let storedAt: Date
        let ttl: Duration
    }

    private var storage: [String: Entry] = [:]
    private var hitCount = 0
    private var missCount = 0
    private let clock: any Clock
    /// Guards against unbounded growth in a long-lived process.
    private let capacity: Int

    public init(capacity: Int = 256, clock: any Clock = SystemClock()) {
        self.capacity = max(8, capacity)
        self.clock = clock
    }

    public func get(_ key: Key) -> SearchResponse? {
        pruneExpired()
        guard let entry = storage[key.digest] else {
            missCount += 1
            return nil
        }
        let age = clock.now().timeIntervalSince(entry.storedAt)
        guard age < entry.ttl.seconds else {
            storage[key.digest] = nil
            missCount += 1
            return nil
        }
        hitCount += 1
        var response = entry.response
        response.servedFromCache = true
        response.elapsedMilliseconds = 0
        return response
    }

    /// Store a successful response. Responses without results are not cached, to
    /// avoid pinning a transient empty result for the TTL.
    public func store(_ response: SearchResponse, for key: Key, ttl: Duration) {
        guard ttl.seconds > 0, response.hasUsableResults else { return }
        storage[key.digest] = Entry(response: response, storedAt: clock.now(), ttl: ttl)
        pruneExpired()
        if storage.count > capacity {
            evictOldest()
        }
    }

    public struct Stats: Sendable, Hashable {
        public let entries: Int
        public let hits: Int
        public let misses: Int
    }

    public func stats() -> Stats {
        pruneExpired()
        return Stats(entries: storage.count, hits: hitCount, misses: missCount)
    }

    private func pruneExpired() {
        let now = clock.now()
        storage = storage.filter { now.timeIntervalSince($0.value.storedAt) < $0.value.ttl.seconds }
    }

    private func evictOldest() {
        let overflow = storage.count - capacity
        guard overflow > 0 else { return }
        let oldest = storage.sorted { $0.value.storedAt < $1.value.storedAt }.prefix(overflow)
        for (key, _) in oldest {
            storage[key] = nil
        }
    }

    nonisolated static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
