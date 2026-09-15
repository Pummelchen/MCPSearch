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
    /// real pages rarely exceed a few dozen, so this rejects pathological input only. It is
    /// deliberately well below the measured death thresholds so that any recursion inside a
    /// parser or a tree walk has room to spare.
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
        if let exceeded = html.utf8.withContiguousStorageIfAvailable({ scan($0, limit: limit) }) {
            return exceeded
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

    /// Count nesting on bytes. No recursion, no per-tag allocation, early exit.
    static func scan<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        limit: Int
    ) -> Bool where Bytes.Element == UInt8, Bytes.Index == Int {
        var depth = 0
        var index = bytes.startIndex
        let end = bytes.endIndex

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

            // A closing tag always returns to the parent, even if it never matched one.
            if bytes[afterBracket] == UInt8(ascii: "/") {
                depth = depth > 0 ? depth - 1 : 0
                index = skip(bytes, from: afterBracket + 1, until: ">", end: end)
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

            if !selfClosing, !matchesAny(bytes, from: tagBody, to: tagNameEnd, in: voidElements) {
                depth += 1
                if depth > limit { return true }
            }
            index = min(cursor + 1, end)
        }
        return false
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
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "/")
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
