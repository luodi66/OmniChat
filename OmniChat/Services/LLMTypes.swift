import Foundation

struct ImagePart {
    var mimeType: String
    var base64: String
}

struct ToolCall {
    var id: String
    var name: String
    var arguments: String
}

enum NeutralMessage {
    case user(text: String, images: [ImagePart])
    /// rawBlocks: Anthropic content blocks (thinking + signature + tool_use) that must be echoed back verbatim.
    case assistant(text: String, toolCalls: [ToolCall], rawBlocks: [[String: Any]]?)
    case toolResult(callID: String, name: String, content: String)
}

struct ToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]

    static let webSearch = ToolSpec(
        name: "web_search",
        description: "Search the web for up-to-date information. Use it when the user asks about recent events or facts you are unsure about. Returns titles, URLs and snippets.",
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "The search query"]
            ],
            "required": ["query"]
        ]
    )
}

struct GenerationSettings {
    var model: String
    var systemPrompt: String
    var temperature: Double?
    var maxTokens: Int
    /// 0 off, 1 low, 2 medium, 3 high
    var thinkingLevel: Int
    var thinkingBudget: Int
    var tools: [ToolSpec]

    var effortString: String? {
        switch thinkingLevel {
        case 1: return "low"
        case 2: return "medium"
        case 3: return "high"
        default: return nil
        }
    }
}

enum StreamEvent {
    case text(String)
    case reasoning(String)
}

struct TurnResult {
    var text: String = ""
    var toolCalls: [ToolCall] = []
    var rawBlocks: [[String: Any]]?
    var stopReason: String?
}

enum LLMError: LocalizedError {
    case invalidURL(String)
    case http(Int, String)
    case api(String)
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return String(localized: "无效的地址: ") + s
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .api(let msg): return msg
        case .missingModel: return String(localized: "请先选择模型")
        }
    }
}

typealias EventHandler = @MainActor (StreamEvent) -> Void

protocol LLMClient {
    func streamTurn(messages: [NeutralMessage], settings: GenerationSettings, onEvent: @escaping EventHandler) async throws -> TurnResult
    func listModels() async throws -> [String]
}

enum LLMClientFactory {
    static func make(protocol p: APIProtocol, baseURL: String, apiKey: String) -> LLMClient {
        switch p {
        case .openAIChat: return OpenAIChatClient(baseURL: baseURL, apiKey: apiKey)
        case .openAIResponses: return OpenAIResponsesClient(baseURL: baseURL, apiKey: apiKey)
        case .anthropic: return AnthropicClient(baseURL: baseURL, apiKey: apiKey)
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    static func url(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path), url.scheme != nil else {
            throw LLMError.invalidURL(b + path)
        }
        return url
    }

    static func jsonRequest(url: URL, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    /// Opens a streaming request and calls `onData` for every SSE `data:` payload.
    static func streamSSE(_ request: URLRequest, onData: (String) async throws -> Bool) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4000 { break }
            }
            throw LLMError.http(status, extractErrorMessage(body))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else {
                // Some servers return plain JSON errors without SSE framing.
                if line.hasPrefix("{"), line.contains("\"error\"") {
                    throw LLMError.api(extractErrorMessage(line))
                }
                continue
            }
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" { break }
            let shouldContinue = try await onData(payload)
            if !shouldContinue { break }
        }
    }

    static func getJSON(url: URL, headers: [String: String]) async throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if !(200..<300).contains(status) {
            throw LLMError.http(status, extractErrorMessage(text))
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    static func extractErrorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        return String(body.prefix(1000))
    }

    static func parse(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
