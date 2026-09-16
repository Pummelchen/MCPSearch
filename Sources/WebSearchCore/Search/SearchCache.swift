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
        /// Absolute deadline. Storing the deadline rather than the TTL means the read path and
        /// the sweep compare the same value, so they cannot disagree at the boundary.
        let expiresAt: Date
    }

    private var storage: [String: Entry] = [:]
    private var hitCount = 0
    private var missCount = 0
    private let clock: any Clock
    /// Guards against unbounded growth in a long-lived process.
    private let capacity: Int
    /// The earliest deadline any stored entry has.
    ///
    /// This is what lets a sweep be skipped without changing what the cache reports: it is only
    /// ever lowered by a store and recomputed by a sweep, so it can be stale-early (the entry it
    /// named was read, swept or evicted) but never stale-late. Stale-early costs one scan that
    /// finds nothing; stale-late would leave an expired entry visible, so the invariant is the
    /// whole argument for the lazy sweep.
    private var nextExpiry: Date?

    public init(capacity: Int = 256, clock: any Clock = SystemClock()) {
        self.capacity = max(8, capacity)
        self.clock = clock
    }

    public func get(_ key: Key) -> SearchResponse? {
        // No sweep here. The requested key is judged directly and an expired entry is removed on
        // the spot, so a read is O(1) in the size of the cache instead of rebuilding the whole
        // dictionary and re-hashing every live entry. Entries that expired without
        // being read are removed by the next sweep, which `stats()` and `store` still run when
        // one is due.
        guard let entry = storage[key.digest] else {
            missCount += 1
            return nil
        }
        guard clock.now() < entry.expiresAt else {
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
        let now = clock.now()
        let entry = Entry(
            response: response,
            storedAt: now,
            expiresAt: now.addingTimeInterval(ttl.seconds)
        )
        storage[key.digest] = entry
        // A store is the only thing that can move the earliest deadline earlier.
        nextExpiry = min(nextExpiry ?? entry.expiresAt, entry.expiresAt)
        // Same order as before the lazy sweep: expire, then enforce the capacity bound.
        sweepExpired(now: now)
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
        sweepExpired(now: clock.now())
        return Stats(entries: storage.count, hits: hitCount, misses: missCount)
    }

    /// Remove every entry whose deadline has passed — but only when one can have.
    ///
    /// `get`, `store` and `stats` used to call this unconditionally, so every search allocated a
    /// new dictionary and re-hashed every live entry even when nothing had expired.
    /// Removal is in place now, and the `nextExpiry` guard means the scan only runs when at least
    /// one entry is actually due. The observable result is unchanged: `get` reports the same
    /// hits and misses, and `stats().entries` still counts live entries only, because an expired
    /// entry always makes the guard true.
    private func sweepExpired(now: Date) {
        guard let earliest = nextExpiry, earliest <= now else { return }
        var expired: [String] = []
        var earliestLive: Date?
        for (key, entry) in storage {
            if entry.expiresAt <= now {
                expired.append(key)
            } else {
                earliestLive = min(earliestLive ?? entry.expiresAt, entry.expiresAt)
            }
        }
        for key in expired {
            storage[key] = nil
        }
        nextExpiry = earliestLive
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
