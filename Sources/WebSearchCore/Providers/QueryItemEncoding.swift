import Foundation

extension URLComponents {
    /// Assign query items with `+` escaped, which Foundation's own setter does not do.
    ///
    /// The `queryItems` setter validates each value against the `.queryItem` allowed mask, and that
    /// mask **includes `+`** — RFC 3986 lists it as a sub-delimiter — so a query of `C++` went out
    /// literally. DuckDuckGo, Startpage and SearXNG are form-style GET endpoints that decode `+` as
    /// a space, so the engine received `C` and answered a different question than the one asked
    /// . The JSON APIs happen to be unaffected because they do not form-decode, but
    /// the encoding is wrong for them too.
    ///
    /// `%2B` is the correct encoding for both kinds of endpoint: a form decoder maps it to `+`, and
    /// a JSON decoder maps it to `+` as well. Everything else keeps the encoding Foundation chose.
    mutating func setQueryItemsEscapingPlus(_ items: [URLQueryItem]) {
        queryItems = items
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}
