import Foundation

struct OpenAIChatClient: LLMClient {
    let baseURL: String
    let apiKey: String

    private var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    func listModels() async throws -> [String] {
        let obj = try await HTTP.getJSON(url: HTTP.url(baseURL, "/models"), headers: headers)
        return OpenAIChatClient.parseModelList(obj)
    }

    static func parseModelList(_ obj: Any) -> [String] {
        var ids: [String] = []
        if let dict = obj as? [String: Any] {
            let list = (dict["data"] as? [[String: Any]]) ?? (dict["models"] as? [[String: Any]]) ?? []
            for item in list {
                if let id = item["id"] as? String { ids.append(id) }
                else if let name = item["name"] as? String { ids.append(name) }
            }
        } else if let list = obj as? [[String: Any]] {
            for item in list { if let id = item["id"] as? String { ids.append(id) } }
        }
        return ids.sorted()
    }

    private func wireMessages(_ messages: [NeutralMessage], system: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for m in messages {
            switch m {
            case .user(let text, let images):
                if images.isEmpty {
                    out.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    for img in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64)"]
                        ])
                    }
                    out.append(["role": "user", "content": parts])
                }
            case .assistant(let text, let toolCalls, _):
                var msg: [String: Any] = ["role": "assistant", "content": text]
                if !toolCalls.isEmpty {
                    msg["tool_calls"] = toolCalls.map { call -> [String: Any] in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments]
                        ]
                    }
                    if text.isEmpty { msg["content"] = NSNull() }
                }
                out.append(msg)
            case .toolResult(let callID, _, let content):
                out.append(["role": "tool", "tool_call_id": callID, "content": content])
            }
        }
        return out
    }

    func streamTurn(messages: [NeutralMessage], settings: GenerationSettings, onEvent: @escaping EventHandler) async throws -> TurnResult {
        guard !settings.model.isEmpty else { throw LLMError.missingModel }
        var body: [String: Any] = [
            "model": settings.model,
            "messages": wireMessages(messages, system: settings.systemPrompt),
            "stream": true
        ]
        if let effort = settings.effort {
            body["reasoning_effort"] = effort
            // Reasoning models expect max_completion_tokens.
            body["max_completion_tokens"] = settings.maxTokens
        } else {
            body["max_tokens"] = settings.maxTokens
            if let t = settings.temperature { body["temperature"] = t }
        }
        if !settings.tools.isEmpty {
            body["tools"] = settings.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
        }

        let request = try HTTP.jsonRequest(url: HTTP.url(baseURL, "/chat/completions"), body: body, headers: headers)

        var result = TurnResult()
        // index -> (id, name, arguments)
        var calls: [Int: ToolCall] = [:]
        var inThinkTag = false

        try await HTTP.streamSSE(request) { payload in
            guard let obj = HTTP.parse(payload) else { return true }
            if let err = obj["error"] as? [String: Any] {
                throw LLMError.api((err["message"] as? String) ?? payload)
            }
            guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { return true }
            if let finish = choice["finish_reason"] as? String { result.stopReason = finish }
            guard let delta = choice["delta"] as? [String: Any] else { return true }

            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            if let r = reasoning, !r.isEmpty {
                await onEvent(.reasoning(r))
            }
            if var content = delta["content"] as? String, !content.isEmpty {
                // Handle inline <think>...</think> used by some open models.
                if content.contains("<think>") {
                    inThinkTag = true
                    content = content.replacingOccurrences(of: "<think>", with: "")
                }
                if inThinkTag {
                    if let range = content.range(of: "</think>") {
                        let thinkPart = String(content[..<range.lowerBound])
                        let rest = String(content[range.upperBound...])
                        inThinkTag = false
                        if !thinkPart.isEmpty { await onEvent(.reasoning(thinkPart)) }
                        if !rest.isEmpty {
                            result.text += rest
                            await onEvent(.text(rest))
                        }
                    } else {
                        await onEvent(.reasoning(content))
                    }
                } else {
                    result.text += content
                    await onEvent(.text(content))
                }
            }
            if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
                for td in toolDeltas {
                    let index = (td["index"] as? Int) ?? 0
                    var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                    if let id = td["id"] as? String, !id.isEmpty { call.id = id }
                    if let fn = td["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty { call.name = name }
                        if let args = fn["arguments"] as? String { call.arguments += args }
                    }
                    calls[index] = call
                }
            }
            return true
        }

        result.toolCalls = calls.keys.sorted().compactMap { idx in
            guard var c = calls[idx], !c.name.isEmpty else { return nil }
            if c.id.isEmpty { c.id = "call_\(idx)_\(UUID().uuidString.prefix(8))" }
            return c
        }
        return result
    }
}
