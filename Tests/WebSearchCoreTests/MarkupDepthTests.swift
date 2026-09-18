import Foundation
import SwiftSoup
import XCTest

@testable import WebSearchCore

/// Regression tests: untrusted markup must never terminate the process.
///
/// Before the guard existed, `DuckDuckGoProvider.search` died with SIGBUS at 5 000 nested
/// elements and `HTMLExtractor.extract` at 20 000. Both parse attacker-controlled markup on a
/// Swift concurrency cooperative task, whose stack a recursive parser exhausts; the failure
/// mode is process death, so every connected MCP client loses service. These tests reuse the
/// same inputs and call paths as the pre-fix probes, which means removing the guard makes them
/// crash the runner instead of failing politely.
final class MarkupDepthTests: XCTestCase {

    /// `<div>` repeated `depth` times, the shape used to measure the thresholds.
    static func nested(_ depth: Int) -> String {
        String(repeating: "<div>", count: depth) + "text"
    }

    // MARK: - Counting nesting

    func testOrdinaryMarkupNestsShallowly() {
        XCTAssertFalse(MarkupDepth.exceedsLimit("<html><body><p>hello</p></body></html>"))
        XCTAssertFalse(MarkupDepth.exceedsLimit(""))
    }

    func testNestingAtTheLimitIsAccepted() {
        XCTAssertFalse(MarkupDepth.exceedsLimit(Self.nested(MarkupDepth.maximumNesting)))
    }

    /// A closing tag that closes nothing must not suppress the depth it does not close.
    ///
    /// The guard's counter decremented on every closing tag, with the comment "a closing tag always
    /// returns to the parent, even if it never matched one". That is false for real HTML: `</p>` with
    /// no open `p` closes nothing, so `<div></p>` repeated nests the `div`s 100 000 deep — 900 KB,
    /// inside the fetch cap — while the counter reads 0 or 1 and the guard never trips. Measured
    /// through `SwiftSoup.parse`, that document did not crash and did not finish within ten minutes
    /// .
    /// The model's depth against the depth SwiftSoup actually builds.
    ///
    /// A bound is only sound if the model never reads *below* the real tree, and only usable if it is
    /// not far above it. The corpus below is the constructs where the two can diverge: the optional end
    /// tags HTML permits, the adoption-agency elements, tables with implied structure, and foreign
    /// content. Every case asserts soundness, because an under-count is the bypass; tightness is
    /// asserted separately, against the divergence each case was measured at.
    func testTheModelDepthIsNeverBelowTheParsedTree() throws {
        let documents: [(String, String)] = [
            ("nested divs", String(repeating: "<div>", count: 40) + "x" + String(repeating: "</div>", count: 40)),
            ("deep then shallow", String(repeating: "<div>", count: 30) + "</div></div></div><span>y</span>"),
            ("omitted </p>", "<p>one<p>two<p>three<p>four<p>five"),
            ("omitted </li>", "<ul><li>a<li>b<li>c<li>d<li>e</ul>"),
            ("omitted </td></tr>", "<table><tr><td>a<td>b<tr><td>c<td>d</table>"),
            ("omitted </dt><dd>", "<dl><dt>a<dd>b<dt>c<dd>d</dl>"),
            ("select options", "<select><option>a<option>b<option>c</select>"),
            ("mixed ordinary", "<div><ul><li><p>text</p></li></ul></div>"),
            ("adoption agency a", String(repeating: "<a>", count: 20) + "x"),
            ("adoption agency b/i", String(repeating: "<b><i>", count: 20) + "x"),
            ("nobr repeated", String(repeating: "<nobr>", count: 20) + "x"),
            ("headings close each other", "<h1>a<h2>b<h3>c<h4>d<h5>e<h6>f"),
            ("button closes button", "<button>a<button>b<button>c"),
            ("form repeated", "<form><form><form>x"),
            ("svg foreign content", "<svg><g><g><g><text>t</text></g></g></g></svg>"),
            ("math foreign content", "<math><mrow><mrow><mi>x</mi></mrow></mrow></math>"),
            (
                "table sections",
                "<table><caption>c</caption><colgroup><col></colgroup><thead><tr><th>h<tbody><tr><td>d</table>"
            ),
            ("nested tables", "<table><tr><td><table><tr><td><table><tr><td>x</table></table></table>"),
            ("select inside a table", "<table><tr><td><select><option>a<option>b</select></table>"),
            ("stray end tags", "</div></p></span><div>a</div></li></ul>"),
            ("li outside a list", "<li>a<li>b<li>c"),
            ("option outside a select", "<option>a<option>b"),
            ("paragraphs with inline", "<p>a<b>b<i>c</i></b><p>d<em>e</em>"),
            ("deep inline", String(repeating: "<span>", count: 60) + "x" + String(repeating: "</span>", count: 60)),
            // A self-closing tag in foreign content, and a void element, are both **elements** at
            // `depth + 1` that never stay open. The model skipped them entirely and read one level
            // short on four of 37 real pages — every one an SVG icon (`<circle/>`, `<line/>`) inside a
            // button. `<br>`, `<img>` and `<input>` are the same shape, so the same shortfall applied
            // to ordinary markup that the hand-written corpus never nested deeply.
            ("self-closing svg counts a level", "<div><svg><g><circle/><line/></g></svg></div>"),
            (
                "void elements count a level",
                String(repeating: "<div>", count: 12) + "<br><img src=\"x\">" + String(repeating: "</div>", count: 12)
            ),
            ("entry then self-closing", "<ul><li>a<br><li>b<br></ul>"),
            ("self-closing html element", "<div><span/><span/></div>"),
            ("svg deep", "<svg><defs><clipPath><rect></rect></clipPath></defs></svg>"),
            ("svg in a button", "<button><svg><line></line></svg></button>"),
            ("svg under a link", "<a><div><svg><defs><clipPath><rect></rect></clipPath></defs></svg></div></a>"),
            (
                "template containing a button",
                "<template><fieldset><div><button><span><svg><path></path></svg></span></button></div></fieldset></template>"
            ),
            (
                "nested templates",
                "<template><div><template><div><template><div>x</div></template></div></template></div></template>"
            ),
            ("text inside svg", "<svg><text><tspan>a</tspan></text></svg>"),
            ("foreignObject", "<svg><foreignObject><div><p>x</p></div></foreignObject></svg>"),
            ("math inside svg", "<svg><foreignObject><math><mrow><mi>x</mi></mrow></math></foreignObject></svg>"),
            (
                "realistic page",
                """
                <div class="page"><header><nav><ul><li><a href="/a">A</a><li><a href="/b">B</a></ul></nav></header>
                <main><article><h1>Title</h1><p>One<p>Two<ul><li>x<li>y</ul>
                <table><tr><th>h<th>h<tbody><tr><td>a<td>b</table>
                <form><label>L<input name="i"></label><button>Go</button></form></article></main>
                <footer><p>f</p></footer></div>
                """
            ),
        ]

        // Divergences measured and accepted. Every other case must be exact.
        let acceptedOverCount: [String: Int] = [
            // A parser ignores a `<form>` start tag while a form is open — a form inside a form creates
            // no element — so the model counts two levels the tree does not have. The markup is
            // invalid, real pages do not contain it, and over-counting is the safe direction.
            "form repeated": 2
        ]

        var exact = 0
        for (label, fragment) in documents {
            // A complete document, so the parser adds no implicit `html`/`body` wrapper. With a bare
            // fragment it always adds two, which the model cannot see: measuring fragments made the
            // model look like it under-counted by a constant 2 when the two levels were the parser's.
            let html = "<!DOCTYPE html><html><head></head><body>" + fragment + "</body></html>"
            let real = try Self.parsedDepth(html)
            let model = MarkupDepth.maximumDepth(html, limit: 100_000)
            if model == real { exact += 1 }
            print("      A0011 \(label): model=\(model) parsed=\(real) delta=\(model - real)")
            XCTAssertGreaterThanOrEqual(
                model,
                real,
                "\(label): the model read \(model) but the parser built \(real) — under-counting is a bypass"
            )
            // Tightness, per case. A lower bound alone would let the model drift upward into a false
            // rejection with no test noticing, which is the failure mode this exercise exists to avoid.
            XCTAssertEqual(
                model - real,
                acceptedOverCount[label] ?? 0,
                "\(label): the model read \(model), the parser built \(real)"
            )
        }
        print("      A0011 exact: \(exact) of \(documents.count)")
    }

    /// What a bare fragment costs on top of the model, which is what the limit is chosen against.
    ///
    /// `web_open` hands a parser a fragment, not a complete document, and the parser inserts an `html`
    /// and a `body` element the bytes never contained and the model cannot see. That constant is the
    /// difference between `maximumNesting` and the tree depth it actually admits.
    func testAFragmentGainsOnlyTheParsersOwnWrapper() throws {
        let fragments = [
            String(repeating: "<div>", count: 50) + "x" + String(repeating: "</div>", count: 50),
            "<p>one<p>two<p>three<ul><li>a<li>b</ul>",
            "<table><tr><td>a<td>b<tr><td>c</table>",
            "<section><article><h1>t</h1><p>b<p>c</article></section>",
        ]

        for (index, fragment) in fragments.enumerated() {
            let real = try Self.parsedDepth(fragment)
            let model = MarkupDepth.maximumDepth(fragment, limit: 100_000)
            print("      A0011 fragment \(index): model=\(model) parsed=\(real)")
            XCTAssertLessThanOrEqual(
                real - model,
                2,
                "fragment \(index): the parser added \(real - model) levels, more than its html/body pair"
            )
        }
    }

    /// The depth model against **real pages**, when a corpus is supplied.
    ///
    /// The corpus above is 25 hand-written constructs. That is enough to catch a regression and it is
    /// not evidence about the web: the model's entire job is to be a sound bound on documents it has
    /// never seen, and a hand-written construct is a document someone already had in mind while writing
    /// the model. This reads whatever HTML is in `MARKUP_DEPTH_CORPUS`, so the claim can be re-checked
    /// against real pages without the default suite needing a network — the same opt-in arrangement as
    /// `LiveProviderTests`.
    ///
    /// An **under-count is a failure** here, not a warning: it is the bypass direction. An over-count
    /// is reported but tolerated, because it costs a refusal rather than a crash, and the point of the
    /// run is to find out how large it gets on pages nobody wrote for this test.
    func testTheModelAgainstARealPageCorpus() throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKUP_DEPTH_CORPUS"] else {
            throw XCTSkip("set MARKUP_DEPTH_CORPUS to a directory of saved .html files")
        }
        let pages = try FileManager.default
            .contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".html") || $0.hasSuffix(".htm") }
            .sorted()
        guard !pages.isEmpty else {
            throw XCTSkip("no .html files in \(directory)")
        }

        var exact = 0
        var overCounts: [(String, Int)] = []
        var underCounts: [(String, Int, Int)] = []

        for page in pages {
            let path = (directory as NSString).appendingPathComponent(page)
            guard let html = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let real = try Self.parsedDepth(html)
            let model = MarkupDepth.maximumDepth(html, limit: 100_000)

            if model == real {
                exact += 1
            } else if model > real {
                overCounts.append((page, model - real))
            } else {
                underCounts.append((page, model, real))
            }
        }

        let measured = exact + overCounts.count + underCounts.count
        print(
            "      A0011 corpus: \(measured) pages, \(exact) exact, \(overCounts.count) over, \(underCounts.count) under"
        )
        for (page, delta) in overCounts.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            print("      A0011 over  +\(delta)  \(page)")
        }
        for (page, model, real) in underCounts.prefix(6) {
            let path = (directory as NSString).appendingPathComponent(page)
            let chain =
                (try? String(contentsOfFile: path, encoding: .utf8))
                .flatMap { try? Self.deepestChain($0) } ?? "?"
            print("      A0011 UNDER \(page): model=\(model) parsed=\(real)")
            print("      A0011 chain: \(chain)")
        }

        XCTAssertTrue(
            underCounts.isEmpty,
            "the model under-counted \(underCounts.count) of \(measured) real pages — that is the bypass direction"
        )
    }

}
