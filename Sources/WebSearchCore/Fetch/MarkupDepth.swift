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
    /// if it is not far above it. Without this, "the model is close enough" is an assertion (ledger
    /// A0011).
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
    private static let voidElements: [[UInt8]] = [
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
    private static let rawTextElements: [[UInt8]] = [
        Array("script".utf8), Array("style".utf8), Array("textarea".utf8), Array("title".utf8),
        Array("xmp".utf8), Array("iframe".utf8), Array("noembed".utf8), Array("noframes".utf8),
        Array("noscript".utf8), Array("plaintext".utf8),
    ]

    /// Bytes of element name each stack slot compares exactly.
    ///
    /// Every HTML element name fits: the longest are `figcaption` (11), `foreignObject` (13) and
    /// `feGaussianBlur` (14).
    private static let nameSlotBytes = 16

    /// Length marker for a name too long to compare exactly. Such a name opens a level and can never
    /// be closed by an end tag, so it can only over-count — the safe direction, since over-counting
    /// refuses a page while under-counting lets a crash through.
    private static let unmatchedNameLength: UInt8 = 0xFF

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
    private static let closesParagraph: [[UInt8]] = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div",
        "dl", "dt", "dd", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hgroup", "hr", "li", "listing", "main", "menu", "nav", "ol",
        "p", "plaintext", "pre", "search", "section", "summary", "table", "ul", "xmp",
    ].map { Array($0.utf8) }

    /// The paragraph element, for the block-closer pass.
    private static let paragraphElement: [[UInt8]] = [Array("p".utf8)]

    /// Table structure, for the section a `<tr>` implies.
    private static let tableSectionElements: [[UInt8]] = ["thead", "tbody", "tfoot"].map {
        Array($0.utf8)
    }
    private static let tableRowElements: [[UInt8]] = ["tr"].map { Array($0.utf8) }
    private static let tableElement: [[UInt8]] = ["table"].map { Array($0.utf8) }
    private static let headingElements: [[UInt8]] = ["h1", "h2", "h3", "h4", "h5", "h6"].map {
        Array($0.utf8)
    }
    private static let anchorElements: [[UInt8]] = ["a"].map { Array($0.utf8) }
    private static let impliedTableSection: [UInt8] = Array("tbody".utf8)

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
    /// (ledger A0011).
    private static let impliedEndTagBoundaries: [[UInt8]] = [
        "ul", "ol", "menu", "dl", "table", "caption", "td", "th", "template",
        "button", "select", "object", "marquee", "applet", "html",
    ].map { Array($0.utf8) }

    /// Elements that close an open element of their own kind.
    ///
    /// Each rule is `(what starts, what it closes)`, and each closes the innermost match. Only the
    /// sets measured to matter are modelled. Finding no match is deliberate and safe: the parser would
    /// still close something, so the model is left **over**-counting rather than under-counting, and
    /// under-counting is the bypass.
    private static let impliedEndTagRules: [(starts: [[UInt8]], closes: [[UInt8]], boundaries: [[UInt8]])] = [
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

    /// Measure nesting on bytes. No recursion, early exit, saturating at `limit + 1`.
    ///
    /// The open elements are a **stack of names**, not a counter, because a counter cannot tell a
    /// closing tag that closes something from one that closes nothing. The counter decremented
    /// unconditionally — "a closing tag always returns to the parent, even if it never matched one" —
    /// and that is false. `<div></p>` repeated exploits it: the `</p>` closes nothing in the real
    /// tree, so the `div`s nest 100 000 deep while the counter reads 0 or 1. A stray end tag is now
    /// ignored, exactly as a parser ignores it (ledger A0011).
    static func scan<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        limit: Int
    ) -> Int where Bytes.Element == UInt8, Bytes.Index == Int {
        var index = bytes.startIndex
        let end = bytes.endIndex

        // One allocation for the document rather than one per tag: names live in a flat byte arena
        // with a length per slot.
        let capacity = min(limit, maximumTrackedDepth) + 1
        var arena = [UInt8](repeating: 0, count: capacity * nameSlotBytes)
        var lengths = [UInt8](repeating: 0, count: capacity)
        var depth = 0
        var deepest = 0

        /// Whether the name in slot `slot` is exactly `candidate`. Stored names are lowercased.
        func slotIs(_ slot: Int, _ candidate: [UInt8]) -> Bool {
            let stored = Int(lengths[slot])
            guard stored != Int(unmatchedNameLength), stored == candidate.count else { return false }
            let base = slot * nameSlotBytes
            var offset = 0
            while offset < candidate.count {
                if arena[base + offset] != candidate[offset] { return false }
                offset += 1
            }
            return true
        }

        /// Pop to the innermost open element matching one of `candidates`, and report whether one was
        /// found. Popping the match takes everything opened inside it, which is what the parser's
        /// "generate implied end tags" plus its pop amounts to.
        /// Whether a table section is open **inside the innermost open table**.
        ///
        /// Scoped to the innermost table, not to the whole stack. A global check looked right and was
        /// not: in `<table><tr><td><table><tr>…` the *outer* section suppressed the inner table's
        /// implicit one, and nested tables then read 7 deep where the parser builds 14 — an
        /// under-count, which is the bypass direction (ledger A0011).
        func sectionOpenInsideInnermostTable() -> Bool {
            var slot = depth - 1
            while slot >= 0 {
                if slotIs(slot, tableElement.first ?? []) { return false }
                for candidate in tableSectionElements where slotIs(slot, candidate) { return true }
                slot -= 1
            }
            return false
        }

        /// Open a level for an element the parser inserts rather than one the bytes contain.
        func pushName(_ name: [UInt8]) {
            guard depth < capacity else { return }
            let base = depth * nameSlotBytes
            for offset in 0..<name.count { arena[base + offset] = name[offset] }
            lengths[depth] = UInt8(name.count)
            depth += 1
            if depth > deepest { deepest = depth }
        }

        /// Pop to the innermost match **above the innermost boundary**, and report whether one was
        /// found. Popping the match takes everything opened inside it, which is what the parser's
        /// implied end tags amount to.
        ///
        /// The boundary is what keeps a walk inside the scope the spec puts it in: list items do not
        /// close across the enclosing list, definition items do not close across the enclosing `dl`,
        /// and a table row does not close across the enclosing table. Returning nothing when no
        /// boundary is open is deliberate — the parser would still close something, so the model stays
        /// over-counting, and under-counting is the bypass.
        @discardableResult
        func popThroughAny(_ candidates: [[UInt8]], boundaries: [[UInt8]] = []) -> Bool {
            var floor = -1
            if !boundaries.isEmpty {
                var slot = depth - 1
                search: while slot >= 0 {
                    for boundary in boundaries where slotIs(slot, boundary) {
                        floor = slot
                        break search
                    }
                    slot -= 1
                }
                if floor < 0 { return false }
            }
            var slot = depth - 1
            while slot > floor {
                for candidate in candidates where slotIs(slot, candidate) {
                    depth = slot
                    return true
                }
                slot -= 1
            }
            return false
        }

        while index < end {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            let afterBracket = index + 1
            guard afterBracket < end else { break }

            // `<!-- … -->` and other declarations (`<!doctype html>`) open nothing.
            if bytes[afterBracket] == UInt8(ascii: "!") {
                if matches(bytes, at: afterBracket, ascii: "!--", end: end) {
                    index = skip(bytes, from: afterBracket + 3, until: "-->", end: end)
                } else {
                    index = skip(bytes, from: afterBracket, until: ">", end: end)
                }
                continue
            }

            // A closing tag pops to the innermost element with that name, and closes nothing at all
            // when no open element has it.
            if bytes[afterBracket] == UInt8(ascii: "/") {
                let nameStart = afterBracket + 1
                let close = skip(bytes, from: nameStart, until: ">", end: end)
                let nameFinish = nameEnd(in: bytes, from: nameStart, to: min(close, end))
                // The name as lowercased bytes, so one comparison serves both paths.
                var name: [UInt8] = []
                name.reserveCapacity(nameFinish - nameStart)
                for offset in nameStart..<nameFinish { name.append(lowercased(bytes[offset])) }
                // No boundary here. A boundary exists to model where an *implied* end tag stops
                // searching; an explicit `</ul>` closes the `ul` it names, and bounding this walk by a
                // set that contains `ul` made the element unclosable. Measured: 35 of 37 real pages
                // over-counted, one by 560 levels, because open elements never came off the stack.
                popThroughAny([name])
                index = close
                continue
            }

            // Only a letter starts a tag; anything else is literal text such as `a < b`.
            guard isASCIILetter(bytes[afterBracket]) else {
                index += 1
                continue
            }

            let tagBody = afterBracket
            var cursor = afterBracket
            var quote: UInt8?
            var selfClosing = false
            while cursor < end {
                let byte = bytes[cursor]
                if let openQuote = quote {
                    if byte == openQuote { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    selfClosing = cursor > tagBody && bytes[cursor - 1] == UInt8(ascii: "/")
                    break
                }
                cursor += 1
            }

            let tagNameEnd = nameEnd(in: bytes, from: tagBody, to: min(cursor, end))

            if !selfClosing, matchesAny(bytes, from: tagBody, to: tagNameEnd, in: rawTextElements) {
                // Raw text: contributes no level, and its content is not markup.
                index = skipRawText(
                    bytes,
                    nameFrom: tagBody,
                    nameTo: tagNameEnd,
                    from: min(cursor + 1, end),
                    end: end
                )
                continue
            }

            // A void element, or a self-closing tag in foreign content, **is** an element: it is a
            // child of its parent at `depth + 1`, it simply never stays open and never has children.
            // Not counting it read one level short on four of 37 real pages, all of them SVG icons
            // (`<circle/>`, `<line/>`) inside a button — and `<br>`, `<img>` and `<input>` are the same
            // shape, so the same shortfall applied to ordinary markup the hand-written corpus happened
            // never to nest deeply (ledger A0011).
            if selfClosing || matchesAny(bytes, from: tagBody, to: tagNameEnd, in: voidElements) {
                if depth + 1 > deepest { deepest = depth + 1 }
                if depth + 1 > limit { return depth + 1 }
                index = min(cursor + 1, end)
                continue
            }

            if !matchesAny(bytes, from: tagBody, to: tagNameEnd, in: voidElements) {
                // An element this start tag implies the end of: close the innermost match first, so
                // the new element opens at the depth the parser gives it and not one level deeper.
                if matchesAny(bytes, from: tagBody, to: tagNameEnd, in: closesParagraph) {
                    popThroughAny(paragraphElement, boundaries: impliedEndTagBoundaries)
                }
                // A `<tr>` with no open table section gets an implicit `<tbody>`: the parser inserts
                // one, so not counting it under-counts every table by a level — and under-counting is
                // the bypass, not a rounding error (ledger A0011).
                if matchesAny(bytes, from: tagBody, to: tagNameEnd, in: tableRowElements),
                    !sectionOpenInsideInnermostTable()
                {
                    pushName(impliedTableSection)
                }
                for rule in impliedEndTagRules
                where matchesAny(bytes, from: tagBody, to: tagNameEnd, in: rule.starts) {
                    popThroughAny(rule.closes, boundaries: rule.boundaries)
                }
                guard depth < capacity else { return limit + 1 }
                let length = tagNameEnd - tagBody
                if length <= nameSlotBytes {
                    let base = depth * nameSlotBytes
                    for offset in 0..<length {
                        arena[base + offset] = lowercased(bytes[tagBody + offset])
                    }
                    lengths[depth] = UInt8(length)
                } else {
                    lengths[depth] = unmatchedNameLength
                }
                depth += 1
                if depth > deepest { deepest = depth }
                if depth > limit { return depth }
            }
            index = min(cursor + 1, end)
        }
        return deepest
    }

    /// Where the tag name ends: the first whitespace or `/`.
    private static func nameEnd<Bytes: RandomAccessCollection>(
        in bytes: Bytes,
        from start: Int,
        to limit: Int
    ) -> Int where Bytes.Element == UInt8, Bytes.Index == Int {
        var index = start
        while index < limit {
            let byte = bytes[index]
            // `>` terminates too: an end tag's name is measured up to the bracket, and the start-tag
            // caller already passes the bracket as its limit, so this only makes the helper safe for
            // both. Without it, `</div>` measured as the name `div>…` up to the next whitespace, so no
            // closing tag ever matched and every ordinary page over-counted (ledger A0011).
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">")
            {
                return index
            }
            index += 1
        }
        return limit
    }

    /// Case-insensitive match of a tag name against one of the fixed element lists.
    private static func matchesAny<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        from start: Int,
        to end: Int,
        in candidates: [[UInt8]]
    ) -> Bool where Bytes.Element == UInt8, Bytes.Index == Int {
        for candidate in candidates where candidate.count == end - start {
            var index = 0
            var matched = true
            while index < candidate.count {
                if lowercased(bytes[start + index]) != candidate[index] {
                    matched = false
                    break
                }
                index += 1
            }
            if matched { return true }
        }
        return false
    }

    /// Index just past the close tag of a raw-text element, or `end` when it never closes.
    ///
    /// An unterminated raw-text element swallows the rest of the document, exactly as a
    /// browser treats it, so the scan stops there.
    private static func skipRawText<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        nameFrom nameStart: Int,
        nameTo nameEnd: Int,
        from start: Int,
        end: Int
    ) -> Int where Bytes.Element == UInt8, Bytes.Index == Int {
        let length = nameEnd - nameStart
        var index = start
        while index + 1 < end {
            if bytes[index] == UInt8(ascii: "<"), bytes[index + 1] == UInt8(ascii: "/"),
                index + 2 + length <= end
            {
                var offset = 0
                var matched = true
                while offset < length {
                    let candidate = bytes[index + 2 + offset]
                    if lowercased(candidate) != lowercased(bytes[nameStart + offset]) {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched, isTagNameTerminator(bytes, at: index + 2 + length, end: end) {
                    return skip(bytes, from: index + 2, until: ">", end: end)
                }
            }
            index += 1
        }
        return end
    }

    private static func isTagNameTerminator<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        at index: Int,
        end: Int
    ) -> Bool where Bytes.Element == UInt8, Bytes.Index == Int {
        guard index < end else { return true }
        let byte = bytes[index]
        return byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    private static func skip<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        from start: Int,
        until terminator: String,
        end: Int
    ) -> Int where Bytes.Element == UInt8, Bytes.Index == Int {
        var index = start
        while index < end {
            if matches(bytes, at: index, ascii: terminator, end: end) {
                return index + terminator.utf8.count
            }
            index += 1
        }
        return end
    }

    private static func matches<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        at start: Int,
        ascii text: String,
        end: Int
    ) -> Bool where Bytes.Element == UInt8, Bytes.Index == Int {
        let pattern = Array(text.utf8)
        guard start + pattern.count <= end else { return false }
        for offset in 0..<pattern.count where bytes[start + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A")) : byte
    }
}
