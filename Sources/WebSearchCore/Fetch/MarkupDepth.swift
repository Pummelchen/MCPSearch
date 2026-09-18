import Foundation

/// Bounds the nesting depth of untrusted markup before it reaches a recursive parser.
///
/// `SwiftSoup` builds and walks the document tree recursively, so a document nested deeply
/// enough exhausts the stack of whatever thread parses it. That matters here because this
/// package parses attacker-controlled markup on a Swift concurrency **cooperative task**,
/// whose stack is a fraction of the main thread's: measured on a debug build, the scraper
/// path died at about 5 000 nested elements and `web_open`'s extraction path at about
/// 20 000, both by SIGBUS, killing the process and every connected MCP client with it.
///
/// A size limit does not bound depth — those documents are only tens of kilobytes — so depth
/// is measured explicitly, iteratively and with an early exit, before any parser sees the
/// input. This type performs no recursion and allocates nothing per tag.
public enum MarkupDepth {

    /// Deepest element nesting any parser in this package will accept.
    ///
    /// The HTML specification and every mainstream browser stop at 512 nested elements, and
    /// real pages rarely exceed a few dozen, so this rejects pathological input only.
    ///
    /// Measured, rather than chosen by feel. The model is exact on complete documents (24 of 25
    /// constructs in `MarkupDepthTests`); a bare *fragment* gains up to two levels the model cannot
    /// see, because a parser inserts an `html` and a `body` element the bytes never contained, so this
    /// limit admits about 514 tree levels. The death threshold this file records is around 20 000
    /// levels, which leaves a margin of roughly 39× for the recursion inside a parser or a tree walk.
    ///
    /// The margin is what the number is for: it is not the largest depth that happens to work, it is
    /// far below the smallest depth measured to fail.
    public static let maximumNesting = 512

    /// Whether `html` nests elements deeper than `limit`.
    ///
    /// Element nesting is measured on the raw bytes, before parsing: comments, declarations,
    /// void elements and self-closing tags do not open a level, the content of raw-text
    /// elements such as `script` and `style` is skipped entirely, a `<` that does not start a
    /// tag is treated as literal text, and a `>` inside a quoted attribute value does not end
    /// a tag. The scan stops as soon as the limit is exceeded, so a hostile document costs a
    /// few kilobytes of reading rather than a full parse.
    public static func exceedsLimit(_ html: String, limit: Int = maximumNesting) -> Bool {
        maximumDepth(html, limit: limit) > limit
    }

    /// The deepest nesting `html` reaches, saturating at `limit + 1`.
    ///
    /// The same single scan as `exceedsLimit`, reporting how deep it got instead of only whether it
    /// got too deep. It exists so the model can be **measured against the tree SwiftSoup actually
    /// builds**: a bound is only sound if this number is never below the real depth, and only usable
    /// if it is not far above it. Without this, "the model is close enough" is an assertion.
    ///
    /// Saturating rather than exact: the scan still stops as soon as the limit is passed, so a hostile
    /// document costs a few kilobytes of reading rather than a full pass. Pass a large `limit` to
    /// measure a real document's depth in full.
    public static func maximumDepth(_ html: String, limit: Int = maximumNesting) -> Int {
        if let depth = html.utf8.withContiguousStorageIfAvailable({ scan($0, limit: limit) }) {
            return depth
        }
        // Non-contiguous UTF-8: one copy is the price of a single code path. `String.utf8`
        // is contiguous for every String this package builds from network data, so this is
        // a fallback rather than the normal route.
        return scan(Array(html.utf8)[...], limit: limit)
    }

    // MARK: - Scanning

    /// Whether `html` contains any markup at all.
    ///
    /// A cheap sniff, used to reject a response body that is plainly not a web page (a JSON
    /// error payload, a rate-limit notice in plain text) before a parser is asked to make
    /// sense of it. As with `exceedsLimit`, a `<` only counts when it starts a tag, so prose
    /// containing a stray less-than sign is still prose.
    public static func containsMarkup(_ html: String) -> Bool {
        let bytes = Array(html.utf8)
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "<") {
                let next = bytes[index + 1]
                if isASCIILetter(next) || next == UInt8(ascii: "/") || next == UInt8(ascii: "!") {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    /// HTML elements that never open a nesting level.
    static let voidElements: [[UInt8]] = [
        Array("area".utf8), Array("base".utf8), Array("br".utf8), Array("col".utf8),
        Array("embed".utf8), Array("hr".utf8), Array("img".utf8), Array("input".utf8),
        Array("link".utf8), Array("meta".utf8), Array("param".utf8), Array("source".utf8),
        Array("track".utf8), Array("wbr".utf8),
    ]

    /// Elements whose content is raw text, never markup.
    ///
    /// Their content must not be scanned for tags: a script bundle full of `<div>` string
    /// literals would otherwise be counted as nesting and reject a perfectly ordinary page.
    /// Because such an element cannot contain elements, it is treated as contributing no
    /// nesting level at all.
    static let rawTextElements: [[UInt8]] = [
        Array("script".utf8), Array("style".utf8), Array("textarea".utf8), Array("title".utf8),
        Array("xmp".utf8), Array("iframe".utf8), Array("noembed".utf8), Array("noframes".utf8),
        Array("noscript".utf8), Array("plaintext".utf8),
    ]

    /// Bytes of element name each stack slot compares exactly.
    ///
    /// Every HTML element name fits: the longest are `figcaption` (11), `foreignObject` (13) and
    /// `feGaussianBlur` (14).
    static let nameSlotBytes = 16

    /// Length marker for a name too long to compare exactly. Such a name opens a level and can never
    /// be closed by an end tag, so it can only over-count — the safe direction, since over-counting
    /// refuses a page while under-counting lets a crash through.
    static let unmatchedNameLength: UInt8 = 0xFF

    /// Most open elements the stack tracks.
    ///
    /// Reaching this is already far past any limit worth enforcing, so a document that gets here is
    /// reported as over the limit rather than grown further.
    static let maximumTrackedDepth = 4096

    /// Elements whose start tag closes an open `<p>`.
    ///
    /// HTML lets `</p>` be omitted, and a parser closes the open paragraph when one of these starts.
    /// `<p>one<p>two<p>three` is three paragraphs at depth one, not one paragraph three deep — and a
    /// model that keeps them open over-counts by one per omitted tag, without bound.
    static let closesParagraph: [[UInt8]] = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div",
        "dl", "dt", "dd", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hgroup", "hr", "li", "listing", "main", "menu", "nav", "ol",
        "p", "plaintext", "pre", "search", "section", "summary", "table", "ul", "xmp",
    ].map { Array($0.utf8) }

    /// The paragraph element, for the block-closer pass.
    static let paragraphElement: [[UInt8]] = [Array("p".utf8)]

    /// Table structure, for the section a `<tr>` implies.
    static let tableSectionElements: [[UInt8]] = ["thead", "tbody", "tfoot"].map {
        Array($0.utf8)
    }
    static let tableRowElements: [[UInt8]] = ["tr"].map { Array($0.utf8) }
    static let tableElement: [[UInt8]] = ["table"].map { Array($0.utf8) }
    private static let headingElements: [[UInt8]] = ["h1", "h2", "h3", "h4", "h5", "h6"].map {
        Array($0.utf8)
    }
    private static let anchorElements: [[UInt8]] = ["a"].map { Array($0.utf8) }
    static let impliedTableSection: [UInt8] = Array("tbody".utf8)

    /// Elements the implied-end-tag walk must not cross.
    ///
    /// The spec walks down from the current node and stops at the first element in the **special**
    /// category that is not `address`, `div` or `p`. Modelling that whole category is out of proportion
    /// here, so this is the subset that both covers the common cases — a nested list, a nested
    /// definition list, a table cell, a template — and appears in the spec's generic "in scope" list,
    /// where crossing it would be wrong in every case.
    ///
    /// What is omitted can only make the model **over**-count: the walk stops late, keeps elements the
    /// parser closed, and over-counting refuses a page rather than letting a deep one through. Measured
    /// against 37 real pages, omitting these was not neutral — it under-counted 18 of them, because
    /// `ul > li > ul > li` is ordinary markup and the walk was popping straight through the inner list
    /// .
    static let impliedEndTagBoundaries: [[UInt8]] = [
        "ul", "ol", "menu", "dl", "table", "caption", "td", "th", "template",
        "button", "select", "object", "marquee", "applet", "html",
    ].map { Array($0.utf8) }

    /// Elements that close an open element of their own kind.
    ///
    /// Each rule is `(what starts, what it closes)`, and each closes the innermost match. Only the
    /// sets measured to matter are modelled. Finding no match is deliberate and safe: the parser would
    /// still close something, so the model is left **over**-counting rather than under-counting, and
    /// under-counting is the bypass.
    static let impliedEndTagRules: [(starts: [[UInt8]], closes: [[UInt8]], boundaries: [[UInt8]])] = [
        (
            ["p"].map { Array($0.utf8) }, ["p"].map { Array($0.utf8) },
            impliedEndTagBoundaries + [Array("button".utf8)]
        ),
        (
            ["li"].map { Array($0.utf8) }, ["li"].map { Array($0.utf8) }, impliedEndTagBoundaries
        ),
        (
            ["dt", "dd"].map { Array($0.utf8) }, ["dt", "dd"].map { Array($0.utf8) },
            impliedEndTagBoundaries
        ),
        (
            ["option"].map { Array($0.utf8) }, ["option"].map { Array($0.utf8) },
            impliedEndTagBoundaries
        ),
        (
            ["optgroup"].map { Array($0.utf8) }, ["optgroup"].map { Array($0.utf8) },
            impliedEndTagBoundaries
        ),
        // A heading start tag closes an open heading, and an `<a>` start tag closes an open `<a>`.
        // Both are the observable effect of adoption-agency handling; without them a page that omits
        // the end tag over-counts by one per element.
        (
            ["h1", "h2", "h3", "h4", "h5", "h6"].map { Array($0.utf8) },
            ["h1", "h2", "h3", "h4", "h5", "h6"].map { Array($0.utf8) },
            impliedEndTagBoundaries
        ),
        (["a"].map { Array($0.utf8) }, ["a"].map { Array($0.utf8) }, impliedEndTagBoundaries),
        // Table structure, scoped to the innermost table: an inner table's row must not close the outer
        // table's row, which is what an unscoped walk did (nested tables read 8 deep where the parser
        // builds 14).
        (["td", "th"].map { Array($0.utf8) }, ["td", "th"].map { Array($0.utf8) }, tableElement),
        (["tr"].map { Array($0.utf8) }, ["tr"].map { Array($0.utf8) }, tableElement),
        (
            ["thead", "tbody", "tfoot"].map { Array($0.utf8) },
            ["thead", "tbody", "tfoot"].map { Array($0.utf8) },
            tableElement
        ),
    ]

}
