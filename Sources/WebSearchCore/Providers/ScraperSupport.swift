import Foundation
import SwiftSoup

/// Shared scaffolding for the opt-in HTML scraper providers.
///
/// Scrapers are explicitly experimental: search-engine markup is not an API
/// contract, changes without notice, and is defended by anti-bot systems. They are
/// therefore disabled by default, rate limited hard, and isolated so that a parser
/// failure degrades to a provider failure instead of a malformed result set.
enum ScraperSupport {
    /// Result of parsing a search-results page.
    struct ParsedPage {
        var results: [ParsedResult]
        var detectedBlock: BlockKind?
        var notes: [String] = []
    }

    /// Why a scraped page yielded nothing. Distinguishing these matters because they
    /// need different operator responses.
    enum BlockKind: String, Sendable {
        /// A bot-challenge / anomaly page was served instead of results.
        case botChallenge = "bot_challenge"
        /// An empty result page.
        case noResults = "no_results"
        /// The page structure did not match any known shape.
        case unknownMarkup = "unknown_markup"
    }

    struct ParsedResult: Sendable {
        var title: String
        var url: String
        var snippet: String?
    }

    /// Markers that indicate an anti-bot interstitial rather than results.
    static let challengeMarkers: [String] = [
        "anomaly", "unusual traffic", "are you a robot", "captcha",
        "verify you are human", "blocked", "automated queries",
        // DuckDuckGo serves its bot challenge with this copy.
        "unfortunately, bots use duckduckgo too", "complete the following challenge",
        "select all squares",
        // Startpage fronts automated access with an Anubis proof-of-work challenge.
        "anubis", "verifying your request", "spchal",
    ]

    /// Detect a bot-challenge page.
    static func detectChallenge(in html: String) -> Bool {
        let lowered = html.lowercased()
        return challengeMarkers.contains { lowered.contains($0) }
    }

    /// Repair a search-engine redirect wrapper and return the real target URL.
    ///
    /// DuckDuckGo wraps result links as `//duckduckgo.com/l/?uddg=<percent-encoded>`;
    /// returning the wrapper would give the model a useless URL.
    static func unwrapRedirect(_ href: String) -> String {
        guard href.contains("uddg=") || href.contains("/l/?") || href.contains("redirect") else {
            return href
        }
        guard let components = URLComponents(string: absolute(href)),
              let items = components.queryItems
        else { return href }

        for name in ["uddg", "url", "u", "q"] {
            if let value = items.first(where: { $0.name == name })?.value,
               value.lowercased().hasPrefix("http")
            {
                return value
            }
        }
        return href
    }

    /// Make a possibly protocol-relative or relative href absolute.
    static func absolute(_ href: String, base: String = "https://duckduckgo.com") -> String {
        if href.hasPrefix("//") { return "https:" + href }
        if href.hasPrefix("http") { return href }
        if href.hasPrefix("/") { return base + href }
        return href
    }

    /// Parse a search results page generically.
    ///
    /// This deliberately does not depend on a single CSS class as a permanent
    /// contract. It first tries a set of candidate selectors, then falls back to a
    /// structural heuristic (anchors with a heading-like text and a plausible
    /// outbound URL). A structure change therefore degrades the result set instead of
    /// failing outright.
    static func parse(
        html: String,
        containerSelectors: [String],
        linkSelectors: [String],
        snippetSelectors: [String],
        base: String,
        excludeHosts: [String],
        provider: ProviderID
    ) throws -> ParsedPage {
        let document: Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            // Report the provider that actually failed rather than a hard-coded one.
            throw SearchError.malformedResponse(provider)
        }

        if detectChallenge(in: html) {
            return ParsedPage(results: [], detectedBlock: .botChallenge)
        }

        var parsed: [ParsedResult] = []
        var seen: Set<String> = []

        for containerSelector in containerSelectors {
            guard let containers = try? document.select(containerSelector),
                  !containers.isEmpty
            else { continue }

            for container in containers {
                guard let link = try? firstMatch(container, selectors: linkSelectors),
                      let href = try? link.attr("href"),
                      !href.isEmpty
                else { continue }

                let target = unwrapRedirect(href)
                let absoluteTarget = absolute(target, base: base)
                guard let url = URL(string: absoluteTarget),
                      let host = url.host()?.lowercased(),
                      !excludeHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
                else { continue }

                let key = URLCanonicalizer.key(for: url)
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let title = ((try? link.text()) ?? "").collapsedWhitespace
                let snippet = (try? firstMatch(container, selectors: snippetSelectors))
                    .flatMap { try? $0.text() }
                    .map { $0.collapsedWhitespace }

                parsed.append(
                    ParsedResult(
                        title: title.isEmpty ? absoluteTarget : title,
                        url: absoluteTarget,
                        snippet: (snippet?.isEmpty ?? true) ? nil : snippet
                    )
                )
            }

            if !parsed.isEmpty { break }
        }

        if parsed.isEmpty {
            parsed = try structuralFallback(
                in: document,
                base: base,
                excludeHosts: excludeHosts
            )
        }

        return ParsedPage(
            results: parsed,
            detectedBlock: parsed.isEmpty ? .unknownMarkup : nil
        )
    }

    /// Last-resort extraction: find anchors that look like result links.
    static func structuralFallback(
        in document: Document,
        base: String,
        excludeHosts: [String]
    ) throws -> [ParsedResult] {
        var parsed: [ParsedResult] = []
        var seen: Set<String> = []
        let anchors = try document.select("a[href]")

        for anchor in anchors {
            guard let href = try? anchor.attr("href"), !href.isEmpty else { continue }
            let target = unwrapRedirect(href)
            let absoluteTarget = absolute(target, base: base)
            guard let url = URL(string: absoluteTarget),
                  let host = url.host()?.lowercased(),
                  !excludeHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            else { continue }

            let text = ((try? anchor.text()) ?? "").collapsedWhitespace
            // Result titles are sentence-like, not single words or long boilerplate.
            guard text.count >= 12, text.count <= 300 else { continue }
            guard text.contains(" ") else { continue }

            let key = URLCanonicalizer.key(for: url)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            parsed.append(ParsedResult(title: text, url: absoluteTarget, snippet: nil))
            if parsed.count >= 30 { break }
        }
        return parsed
    }

    static func firstMatch(_ root: Element, selectors: [String]) throws -> Element? {
        for selector in selectors {
            if let element = try? root.select(selector).first() { return element }
        }
        return nil
    }
}
