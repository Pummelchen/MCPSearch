import Foundation
import SwiftSoup

/// The readable form of an HTML document.
public struct HTMLDocument: Sendable, Hashable {
    public var title: String?
    public var text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

extension HTMLDocument {
    /// Alias used by the fetchers, which care only about the extraction result.
    public typealias Extraction = HTMLDocument
}

/// Boilerplate-removing readable-text extraction built on SwiftSoup.
///
/// This is deliberately a *readability-style heuristic*, not a renderer. It removes
/// elements that are never prose — scripts, styles, navigation, footers, cookie
/// banners — and prefers semantic content regions, then flattens the remainder to
/// text with light structure preserved.
public enum HTMLExtractor {
    /// Tags whose contents are never article prose.
    public static let droppedTags: Set<String> = [
        "script", "style", "noscript", "template", "svg", "canvas", "iframe",
        "object", "embed", "form", "input", "select", "textarea", "button",
        "nav", "footer", "header", "aside", "menu", "dialog",
    ]

    /// Class/id substrings that reliably indicate chrome rather than content.
    public static let boilerplateMarkers: [String] = [
        "nav", "navbar", "navigation", "menu", "sidebar", "side-bar", "footer",
        "header", "masthead", "breadcrumb", "cookie", "consent", "gdpr", "banner",
        "advert", "ads", "sponsor", "promo", "social", "share",
        "comment", "disqus", "related", "recommend", "newsletter", "subscribe",
        "signup", "login", "modal", "popup", "overlay", "skip-link", "pagination",
        "pager", "toolbar", "widget", "meta-bar", "site-header", "site-footer",
    ]

    /// Match a class/id string against the boilerplate markers.
    ///
    /// Matching is token-based rather than raw substring, because a substring test
    /// on a short marker such as `nav` or `promo` produces false positives
    /// (`navy`, `innovate`) that would delete real content. Tokens are extracted by
    /// splitting on anything that is not a letter or digit, and both exact matches
    /// and marker-prefixed tokens (`advert-banner`) count.
    static func matchesBoilerplateMarker(_ identifier: String) -> Bool {
        // Split on anything that is not a letter, a digit or a hyphen: the marker list contains
        // hyphenated names (`side-bar`, `skip-link`, `site-header`), and splitting hyphens away as
        // well made those markers unmatchable and left the "marker then a hyphen" clause
        // unreachable, because a token can never contain the hyphen it tested for (ledger B61).
        let tokens =
            identifier
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") })
            .map { String($0) }
        guard !tokens.isEmpty else { return false }
        for marker in boilerplateMarkers {
            let needle = marker.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !needle.isEmpty else { continue }
            // Exact, or the marker as a hyphen-delimited part: `side-bar-inner` and
            // `wrapper-side-bar` are both chrome, while `sidebar` and `side` are untouched unless
            // they are markers themselves.
            for token in tokens
            where token == needle || token.hasPrefix(needle + "-") || token.hasSuffix("-" + needle) {
                return true
            }
        }
        return false
    }

    /// Containers that typically hold the main content, in preference order.
    public static let contentSelectors: [String] = [
        "article", "main", "[role=main]", "#content", "#main", ".content",
        ".post-content", ".entry-content", ".article-body", ".markdown-body",
        "div.body", "section",
    ]

    /// Extract readable text.
    ///
    /// - Throws: `SearchError.invalidRequest` when the markup cannot be parsed, and
    ///   `SearchError.markupDepthExceeded` when it nests too deeply to parse safely.
    public static func extract(html: String) throws -> HTMLDocument.Extraction {
        // Web pages are fetched from arbitrary URLs and parsed on a cooperative task, whose
        // stack a deeply nested document overflows: measured, about 20 000 levels of nesting
        // killed the process. Bound the depth before the recursive parser runs, then give the
        // parser a stack with room for the bound.
        guard !MarkupDepth.exceedsLimit(html) else {
            throw SearchError.markupDepthExceeded(MarkupDepth.maximumNesting)
        }
        return try LargeStackParse.run { try extractOnCurrentThread(html: html) }
    }

    /// The parse and traversal themselves; recursive, so they run on `LargeStackParse`'s
    /// thread in production and directly in tests that assert the threshold.
    static func extractOnCurrentThread(html: String) throws -> HTMLDocument.Extraction {
        let document: Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            throw SearchError.invalidRequest("HTML could not be parsed")
        }

        let title = (try? document.title()).flatMap { $0.isEmpty ? nil : $0 }

        // Remove non-prose elements outright. Removing is cheaper and more reliable
        // than trying to filter them out of the rendered text later.
        for tag in droppedTags {
            // `select` is the throwing call here; `remove` mutates in place.
            try document.select(tag).remove()
        }

        // Drop boilerplate by class/id marker. This is a heuristic, which is why the
        // marker list is explicit and testable rather than clever.
        try? removeBoilerplate(from: document)

        let root = preferredContentRoot(in: document) ?? document.body() ?? document

        let text = try renderText(root)
        return HTMLDocument.Extraction(
            title: title.map { ResultNormalizer.cleanText($0) ?? $0 },
            text: text
        )
    }

    // MARK: - Internals

    static func removeBoilerplate(from document: Document) throws {
        // Only consider a bounded set of candidates: scanning every element on a
        // large page is needlessly slow.
        let candidates = try document.select("div, section, aside, nav, header, footer, ul, form")
        for element in candidates {
            // `id()` is a plain accessor; `className()` declares `throws`.
            let identifier = element.id() + " " + ((try? element.className()) ?? "")
            let lowered = identifier.lowercased()
            guard !lowered.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if HTMLExtractor.matchesBoilerplateMarker(lowered) {
                // Never remove a node that holds the entire document body.
                if element.parent() == nil { continue }
                try element.remove()
            }
        }
    }

    /// Choose the densest plausible content container.
    ///
    /// Scores candidates by the amount of text they contain after boilerplate
    /// removal, so a page whose `<main>` is a stub but whose `.article-body` is the
    /// real content still extracts correctly.
    static func preferredContentRoot(in document: Document) -> Element? {
        let body = document.body()
        var best: Element?
        var bestScore = 0

        // Score only the candidates that no other candidate contains. `Element.text()` walks the
        // whole subtree and a container's text includes everything inside it, so a candidate
        // nested in another can never outscore it — scoring it would re-walk text that has
        // already been counted. A page that nests its containers, which crafted markup can force,
        // therefore cost quadratic work: on 2 000 nested `<div>`s the scoring pass walked four
        // million nodes and built a string for each (ledger B28). The maximal candidates are
        // found in one depth-first pass and their subtrees are disjoint, so scoring is linear in
        // the document. The selector-major order and the strict `>` comparison are unchanged, so
        // which root wins is unchanged too — except where a nested candidate tied with its
        // container, and the container (the same text plus its siblings) now wins.
        let maximal = maximalCandidates(in: document)
        for selector in contentSelectors {
            guard let elements = try? document.select(selector) else { continue }
            for element in elements where maximal.contains(ObjectIdentifier(element)) {
                let score = estimateTextLength(element)
                if score > bestScore {
                    bestScore = score
                    best = element
                }
            }
        }

        // Require a meaningful amount of text before trusting a container over the
        // whole body; otherwise a short `<section>` would discard the rest.
        guard bestScore >= 200 else { return body }
        return best ?? body
    }

    /// The candidates with no candidate ancestor, in one depth-first pass over the document.
    ///
    /// A candidate is maximal when its subtree is not inside another candidate's: those are the
    /// only ones whose `text()` has to be computed, and because maximal candidates never nest,
    /// their subtrees are disjoint — the scoring pass touches each node once.
    static func maximalCandidates(in document: Document) -> Set<ObjectIdentifier> {
        let union = contentSelectors.joined(separator: ", ")
        guard let candidates = try? document.select(union) else { return [] }
        let collector = MaximalCandidateCollector(
            candidateIDs: Set(candidates.map(ObjectIdentifier.init))
        )
        try? NodeTraversor(collector).traverse(document)
        return collector.maximal
    }

    /// Records candidates that are not inside another candidate, using the traversor's depth.
    ///
    /// A class because `NodeTraversor` calls back into it; the mutable state is confined to the
    /// traversal, which is synchronous.
    private final class MaximalCandidateCollector: NodeVisitor {
        private let candidateIDs: Set<ObjectIdentifier>
        /// Depths of the candidates on the current path, innermost last.
        private var openDepths: [Int] = []
        private(set) var maximal: Set<ObjectIdentifier> = []

        init(candidateIDs: Set<ObjectIdentifier>) {
            self.candidateIDs = candidateIDs
        }

        func head(_ node: Node, _ depth: Int) throws {
            guard let element = node as? Element, candidateIDs.contains(ObjectIdentifier(element))
            else { return }
            // No candidate is open, so nothing above this node contains it.
            if openDepths.isEmpty { maximal.insert(ObjectIdentifier(element)) }
            openDepths.append(depth)
        }

        func tail(_ node: Node, _ depth: Int) throws {
            guard let element = node as? Element, candidateIDs.contains(ObjectIdentifier(element))
            else { return }
            if openDepths.last == depth { openDepths.removeLast() }
        }
    }

    static func estimateTextLength(_ element: Element) -> Int {
        let raw = (try? element.text()) ?? ""
        return raw.count
    }

    /// Flatten an element to text, preserving paragraph and list structure with
    /// newlines so the result stays readable for a model.
    static func renderText(_ root: Element) throws -> String {
        var builder = TextBuilder()
        try walk(root, into: &builder)
        return normalizeWhitespace(builder.finish())
    }

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "br", "hr", "li", "tr", "td", "th",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "figcaption",
        "dd", "dt", "table", "ul", "ol", "header", "footer", "aside", "nav",
    ]

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    static func walk(_ node: Node, into builder: inout TextBuilder) throws {
        if let textNode = node as? TextNode {
            let text = textNode.getWholeText()
            if !text.isEmpty { builder.append(text) }
            return
        }

        guard let element = node as? Element else {
            for child in node.getChildNodes() { try walk(child, into: &builder) }
            return
        }

        let tag = element.tagName().lowercased()

        // Skip hidden elements: `display:none` content is never article prose.
        if let style = try? element.attr("style"),
            style.replacingOccurrences(of: " ", with: "").lowercased().contains("display:none")
        {
            return
        }
        if element.hasAttr("hidden") { return }

        let isBlock = blockTags.contains(tag)
        let isHeading = headingTags.contains(tag)
        let isListItem = tag == "li"

        if isBlock { builder.newline() }
        if isHeading {
            builder.newline()
            builder.newline()
        }
        if isListItem {
            builder.newline()
            builder.append("– ")
        }

        for child in element.getChildNodes() {
            try walk(child, into: &builder)
        }

        if isHeading || isBlock || isListItem {
            builder.newline()
            if isHeading { builder.newline() }
        }
    }

    /// Collapse runs of whitespace while preserving deliberate line structure.
    static func normalizeWhitespace(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = String(rawLine).collapsedWhitespace
            if collapsed.isEmpty {
                // Keep at most one blank line as a paragraph separator.
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(collapsed)
            }
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Accumulates text with inexpensive newline deduplication.
    struct TextBuilder {
        private var buffer = ""
        private var lastWasNewline = true

        mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            buffer += text
            lastWasNewline = false
        }

        mutating func newline() {
            guard !lastWasNewline else { return }
            buffer += "\n"
            lastWasNewline = true
        }

        mutating func finish() -> String { buffer }
    }
}
