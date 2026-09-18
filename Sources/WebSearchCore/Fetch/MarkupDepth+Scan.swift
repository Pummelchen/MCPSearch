import Foundation

extension MarkupDepth {

    /// Measure nesting on bytes. No recursion, early exit, saturating at `limit + 1`.
    ///
    /// The open elements are a **stack of names**, not a counter, because a counter cannot tell a
    /// closing tag that closes something from one that closes nothing. The counter decremented
    /// unconditionally — "a closing tag always returns to the parent, even if it never matched one" —
    /// and that is false. `<div></p>` repeated exploits it: the `</p>` closes nothing in the real
    /// tree, so the `div`s nest 100 000 deep while the counter reads 0 or 1. A stray end tag is now
    /// ignored, exactly as a parser ignores it.
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
        /// under-count, which is the bypass direction.
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
            // never to nest deeply.
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
                // the bypass, not a rounding error.
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
            // closing tag ever matched and every ordinary page over-counted.
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

    static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A")) : byte
    }
}
