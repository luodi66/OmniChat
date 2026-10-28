import Foundation

struct OpenAIResponsesClient: LLMClient {
    let baseURL: String
    let apiKey: String

    private var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    func listModels() async throws -> [String] {
        let obj = try await HTTP.getJSON(url: HTTP.url(baseURL, "/models"), headers: headers)
        return OpenAIChatClient.parseModelList(obj)
    }

    private func wireInput(_ messages: [NeutralMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            switch m {
            case .user(let text, let images):
                var parts: [[String: Any]] = []
                if !text.isEmpty || images.isEmpty { parts.append(["type": "input_text", "text": text]) }
                for img in images {
                    parts.append(["type": "input_image", "image_url": "data:\(img.mimeType);base64,\(img.base64)"])
                }
                out.append(["role": "user", "content": parts])
            case .assistant(let text, let toolCalls, _):
                if !text.isEmpty {
                    out.append(["role": "assistant", "content": text])
                }
                for call in toolCalls {
                    out.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.arguments
                    ])
                }
            case .toolResult(let callID, _, let content):
                out.append(["type": "function_call_output", "call_id": callID, "output": content])
            }
        }
        return out
    }

    func streamTurn(messages: [NeutralMessage], settings: GenerationSettings, onEvent: @escaping EventHandler) async throws -> TurnResult {
        guard !settings.model.isEmpty else { throw LLMError.missingModel }
        var body: [String: Any] = [
            "model": settings.model,
            "input": wireInput(messages),
            "stream": true,
            "store": false,
            "max_output_tokens": settings.maxTokens
        ]
        if !settings.systemPrompt.isEmpty { body["instructions"] = settings.systemPrompt }
        if let effort = settings.effortString {
            body["reasoning"] = ["effort": effort, "summary": "auto"]
        } else if let t = settings.temperature {
            body["temperature"] = t
        }
        if !settings.tools.isEmpty {
            body["tools"] = settings.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            }
        }

        let request = try HTTP.jsonRequest(url: HTTP.url(baseURL, "/responses"), body: body, headers: headers)
        var result = TurnResult()
        var lastSummaryIndex: Int?

        try await HTTP.streamSSE(request) { payload in
            guard let obj = HTTP.parse(payload) else { return true }
            let type = (obj["type"] as? String) ?? ""
            switch type {
            case "response.output_text.delta":
                if let d = obj["delta"] as? String {
                    result.text += d
                    await onEvent(.text(d))
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let idx = obj["summary_index"] as? Int {
                    if let last = lastSummaryIndex, last != idx {
                        await onEvent(.reasoning("\n\n"))
                    }
                    lastSummaryIndex = idx
                }
                if let d = obj["delta"] as? String { await onEvent(.reasoning(d)) }
            case "response.output_item.done":
                if let item = obj["item"] as? [String: Any], (item["type"] as? String) == "function_call" {
                    let call = ToolCall(
                        id: (item["call_id"] as? String) ?? UUID().uuidString,
                        name: (item["name"] as? String) ?? "",
                        arguments: (item["arguments"] as? String) ?? "{}"
                    )
                    result.toolCalls.append(call)
                }
            case "response.completed":
                result.stopReason = "completed"
                return false
            case "response.incomplete":
                result.stopReason = "incomplete"
                return false
            case "response.failed":
                let resp = obj["response"] as? [String: Any]
                let err = resp?["error"] as? [String: Any]
                throw LLMError.api((err?["message"] as? String) ?? "response.failed")
            case "error":
                let msg = (obj["message"] as? String)
                    ?? ((obj["error"] as? [String: Any])?["message"] as? String)
                    ?? payload
                throw LLMError.api(msg)
            default:
                break
            }
            return true
        }
        return result
    }
}
