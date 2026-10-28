import Foundation

enum SearchBackend: String, CaseIterable, Identifiable {
    case auto
    case tavily
    case duckduckgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "自动 (有 Tavily Key 时用 Tavily)")
        case .tavily: return "Tavily"
        case .duckduckgo: return "DuckDuckGo"
        }
    }
}

struct SearchResult {
    var title: String
    var url: String
    var snippet: String
}

enum WebSearchService {
    static let tavilyKeyName = "search.tavily"
    static let backendDefaultsKey = "searchBackend"
    static let resultCountKey = "searchResultCount"

    static var tavilyKey: String {
        get { KeychainStore.get(tavilyKeyName) ?? "" }
        set { KeychainStore.set(newValue, for: tavilyKeyName) }
    }

    static func search(_ query: String) async throws -> [SearchResult] {
        let backend = SearchBackend(rawValue: UserDefaults.standard.string(forKey: backendDefaultsKey) ?? "auto") ?? .auto
        let stored = UserDefaults.standard.integer(forKey: resultCountKey)
        let count = stored > 0 ? stored : 5
        let key = tavilyKey
        switch backend {
        case .tavily:
            return try await tavily(query, key: key, count: count)
        case .duckduckgo:
            return try await duckDuckGo(query, count: count)
        case .auto:
            if !key.isEmpty {
                return try await tavily(query, key: key, count: count)
            }
            return try await duckDuckGo(query, count: count)
        }
    }

    /// Formats results as plain text to feed back to the model.
    static func format(_ results: [SearchResult], query: String) -> String {
        if results.isEmpty { return "No results found for: \(query)" }
        var lines: [String] = ["Search results for: \(query)", ""]
        for (i, r) in results.enumerated() {
            lines.append("[\(i + 1)] \(r.title)")
            lines.append("URL: \(r.url)")
            lines.append(r.snippet)
            lines.append("")
        }
        lines.append("Cite sources with their URLs when you use them.")
        return lines.joined(separator: "\n")
    }

    static func tavily(_ query: String, key: String, count: Int) async throws -> [SearchResult] {
        guard !key.isEmpty else { throw LLMError.api(String(localized: "未设置 Tavily API Key")) }
        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["api_key": key, "query": query, "max_results": count, "search_depth": "basic"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, HTTP.extractErrorMessage(String(data: data, encoding: .utf8) ?? ""))
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let results = (obj?["results"] as? [[String: Any]]) ?? []
        return results.map {
            SearchResult(
                title: ($0["title"] as? String) ?? "",
                url: ($0["url"] as? String) ?? "",
                snippet: ($0["content"] as? String) ?? ""
            )
        }
    }

    static func duckDuckGo(_ query: String, count: Int) async throws -> [SearchResult] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        req.httpBody = Data("q=\(q)&kl=wt-wt".utf8)
        let (data, response) = try await HTTP.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, "DuckDuckGo")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseDuckDuckGo(html, limit: count)
    }

    static func parseDuckDuckGo(_ html: String, limit: Int) -> [SearchResult] {
        let linkPattern = "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        let linkPattern2 = "<a[^>]*href=\"([^\"]+)\"[^>]*class=\"result__a\"[^>]*>(.*?)</a>"
        let snippetPattern = "class=\"result__snippet\"[^>]*>(.*?)</a>"
        let ns = html as NSString
        let opts: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]

        var links: [(String, String)] = []
        for pattern in [linkPattern, linkPattern2] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { continue }
            let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 3 {
                links.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
            }
            if !links.isEmpty { break }
        }
        var snippets: [String] = []
        if let re = try? NSRegularExpression(pattern: snippetPattern, options: opts) {
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
                snippets.append(ns.substring(with: m.range(at: 1)))
            }
        }
        var results: [SearchResult] = []
        for (i, link) in links.enumerated() {
            let url = decodeDuckURL(link.0)
            if url.contains("duckduckgo.com/y.js") { continue } // ads
            let snippet = i < snippets.count ? snippets[i] : ""
            results.append(SearchResult(title: stripHTML(link.1), url: url, snippet: stripHTML(snippet)))
            if results.count >= limit { break }
        }
        return results
    }

    static func decodeDuckURL(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&amp;", with: "&")
        if s.hasPrefix("//") { s = "https:" + s }
        if let comps = URLComponents(string: s),
           let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return s
    }

    static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
