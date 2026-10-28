import Foundation

struct AnthropicClient: LLMClient {
    let baseURL: String
    let apiKey: String

    private var headers: [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01"
        ]
    }

    private func endpoint(_ path: String) throws -> URL {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") {
            return try HTTP.url(b, path)
        }
        return try HTTP.url(b, "/v1" + path)
    }

    func listModels() async throws -> [String] {
        let obj = try await HTTP.getJSON(url: endpoint("/models?limit=1000"), headers: headers)
        return OpenAIChatClient.parseModelList(obj)
    }

    private func wireMessages(_ messages: [NeutralMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                out.append(["role": "user", "content": pendingToolResults])
                pendingToolResults = []
            }
        }

        for m in messages {
            switch m {
            case .user(let text, let images):
                flushToolResults()
                var parts: [[String: Any]] = []
                for img in images {
                    parts.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": img.mimeType, "data": img.base64]
                    ])
                }
                parts.append(["type": "text", "text": text.isEmpty ? " " : text])
                out.append(["role": "user", "content": parts])
            case .assistant(let text, let toolCalls, let rawBlocks):
                flushToolResults()
                if let raw = rawBlocks, !raw.isEmpty {
                    out.append(["role": "assistant", "content": raw])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    for call in toolCalls {
                        let input = HTTP.parse(call.arguments) ?? [:]
                        parts.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                    }
                    if parts.isEmpty { parts.append(["type": "text", "text": " "]) }
                    out.append(["role": "assistant", "content": parts])
                }
            case .toolResult(let callID, _, let content):
                pendingToolResults.append(["type": "tool_result", "tool_use_id": callID, "content": content])
            }
        }
        flushToolResults()
        return out
    }

    func streamTurn(messages: [NeutralMessage], settings: GenerationSettings, onEvent: @escaping EventHandler) async throws -> TurnResult {
        guard !settings.model.isEmpty else { throw LLMError.missingModel }
        var body: [String: Any] = [
            "model": settings.model,
            "messages": wireMessages(messages),
            "stream": true
        ]
        if !settings.systemPrompt.isEmpty { body["system"] = settings.systemPrompt }
        var maxTokens = settings.maxTokens
        if let requested = settings.thinkingBudget {
            let budget = max(1024, requested)
            if maxTokens <= budget { maxTokens = budget + 4096 }
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        } else if let t = settings.temperature {
            body["temperature"] = t
        }
        body["max_tokens"] = maxTokens
        if !settings.tools.isEmpty {
            body["tools"] = settings.tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "input_schema": tool.parameters]
            }
        }

        let request = try HTTP.jsonRequest(url: endpoint("/messages"), body: body, headers: headers)
        var result = TurnResult()
        var blocks: [Int: [String: Any]] = [:]
        var toolJSON: [Int: String] = [:]

        try await HTTP.streamSSE(request) { payload in
            guard let obj = HTTP.parse(payload) else { return true }
            let type = (obj["type"] as? String) ?? ""
            let index = (obj["index"] as? Int) ?? 0
            switch type {
            case "content_block_start":
                if var block = obj["content_block"] as? [String: Any] {
                    let btype = (block["type"] as? String) ?? ""
                    if btype == "text" { block["text"] = (block["text"] as? String) ?? "" }
                    if btype == "thinking" { block["thinking"] = (block["thinking"] as? String) ?? "" }
                    if btype == "tool_use" { toolJSON[index] = "" }
                    blocks[index] = block
                }
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any] else { return true }
                var block = blocks[index] ?? [:]
                switch (delta["type"] as? String) ?? "" {
                case "text_delta":
                    let t = (delta["text"] as? String) ?? ""
                    block["text"] = ((block["text"] as? String) ?? "") + t
                    result.text += t
                    await onEvent(.text(t))
                case "thinking_delta":
                    let t = (delta["thinking"] as? String) ?? ""
                    block["thinking"] = ((block["thinking"] as? String) ?? "") + t
                    await onEvent(.reasoning(t))
                case "signature_delta":
                    block["signature"] = ((block["signature"] as? String) ?? "") + ((delta["signature"] as? String) ?? "")
                case "input_json_delta":
                    toolJSON[index] = (toolJSON[index] ?? "") + ((delta["partial_json"] as? String) ?? "")
                default:
                    break
                }
                blocks[index] = block
            case "content_block_stop":
                if var block = blocks[index], (block["type"] as? String) == "tool_use" {
                    let json = toolJSON[index] ?? ""
                    let input = HTTP.parse(json.isEmpty ? "{}" : json) ?? [:]
                    block["input"] = input
                    blocks[index] = block
                    result.toolCalls.append(ToolCall(
                        id: (block["id"] as? String) ?? UUID().uuidString,
                        name: (block["name"] as? String) ?? "",
                        arguments: json.isEmpty ? "{}" : json
                    ))
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                    result.stopReason = stop
                }
            case "message_stop":
                return false
            case "error":
                let err = obj["error"] as? [String: Any]
                throw LLMError.api((err?["message"] as? String) ?? payload)
            default:
                break
            }
            return true
        }

        result.rawBlocks = blocks.keys.sorted().compactMap { blocks[$0] }
        return result
    }
}
