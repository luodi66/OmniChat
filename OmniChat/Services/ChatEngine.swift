import Foundation
import SwiftData
import SwiftUI

struct StreamState {
    var messageID: UUID
    var text: String = ""
    var reasoning: String = ""
    var toolLog: String = ""
    var status: String = ""
    var notice: String = ""
}

@MainActor
final class ChatEngine: ObservableObject {
    @Published private(set) var streams: [UUID: StreamState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    static let maxToolRounds = 6

    func isGenerating(_ conversation: Conversation) -> Bool {
        streams[conversation.id] != nil
    }

    func streamState(for conversation: Conversation) -> StreamState? {
        streams[conversation.id]
    }

    func stop(_ conversation: Conversation) {
        tasks[conversation.id]?.cancel()
    }

    // MARK: - Public actions

    func send(text: String, attachments: [Attachment], in conversation: Conversation, context: ModelContext) {
        guard !isGenerating(conversation) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let msg = ChatMessage(role: "user", content: trimmed, order: conversation.nextOrder, attachments: attachments)
        msg.conversation = conversation
        conversation.messages.append(msg)
        if conversation.title.isEmpty {
            let source = trimmed.isEmpty ? (attachments.first?.filename ?? "") : trimmed
            conversation.title = String(source.replacingOccurrences(of: "\n", with: " ").prefix(40))
        }
        conversation.updatedAt = Date()
        try? context.save()
        generate(in: conversation, context: context)
    }

    /// Removes the last assistant reply (and anything after the last user message) and regenerates.
    func regenerate(in conversation: Conversation, context: ModelContext) {
        guard !isGenerating(conversation) else { return }
        let sorted = conversation.sortedMessages
        guard let lastUserIndex = sorted.lastIndex(where: { $0.isUser }) else { return }
        for m in sorted[(lastUserIndex + 1)...] {
            delete(m, from: conversation, context: context)
        }
        try? context.save()
        generate(in: conversation, context: context)
    }

    /// Edits a user message, deletes everything after it, and regenerates.
    func edit(_ message: ChatMessage, newText: String, in conversation: Conversation, context: ModelContext) {
        guard !isGenerating(conversation) else { return }
        message.content = newText
        let sorted = conversation.sortedMessages
        if let idx = sorted.firstIndex(where: { $0.id == message.id }) {
            for m in sorted[(idx + 1)...] {
                delete(m, from: conversation, context: context)
            }
        }
        try? context.save()
        if message.isUser {
            generate(in: conversation, context: context)
        }
    }

    func delete(_ message: ChatMessage, from conversation: Conversation, context: ModelContext) {
        conversation.messages.removeAll { $0.id == message.id }
        context.delete(message)
    }

    // MARK: - Generation

    private func resolveProvider(_ conversation: Conversation, context: ModelContext) -> ProviderConfig? {
        let all = (try? context.fetch(FetchDescriptor<ProviderConfig>())) ?? []
        if let pid = conversation.providerID, let p = all.first(where: { $0.id == pid }) {
            return p
        }
        return nil
    }

    private func buildNeutralMessages(_ conversation: Conversation) -> [NeutralMessage] {
        var out: [NeutralMessage] = []
        for m in conversation.sortedMessages {
            if m.isUser {
                var text = m.content
                var images: [ImagePart] = []
                for att in m.attachments {
                    switch att.kind {
                    case .image:
                        if let d = att.data {
                            images.append(ImagePart(mimeType: att.mimeType, base64: d.base64EncodedString()))
                        }
                    case .text:
                        let body = att.text ?? ""
                        text += "\n\n[Attached file: \(att.filename)]\n```\n\(body)\n```"
                    }
                }
                out.append(.user(text: text, images: images))
            } else {
                if m.isError || m.content.isEmpty { continue }
                out.append(.assistant(text: m.content, toolCalls: [], rawBlocks: nil))
            }
        }
        // Merge consecutive user messages (e.g. after a failed reply) to keep strict APIs happy.
        var merged: [NeutralMessage] = []
        for msg in out {
            if case .user(let t2, let i2) = msg, let last = merged.last, case .user(let t1, let i1) = last {
                merged[merged.count - 1] = .user(text: t1 + "\n\n" + t2, images: i1 + i2)
            } else {
                merged.append(msg)
            }
        }
        return merged
    }

    private func generate(in conversation: Conversation, context: ModelContext) {
        let assistant = ChatMessage(role: "assistant", content: "", order: conversation.nextOrder)
        assistant.conversation = conversation
        assistant.modelName = conversation.model
        conversation.messages.append(assistant)
        try? context.save()

        guard let provider = resolveProvider(conversation, context: context) else {
            assistant.isError = true
            assistant.content = String(localized: "未选择服务商。请在对话设置中选择服务商和模型。")
            try? context.save()
            return
        }

        let convID = conversation.id
        streams[convID] = StreamState(messageID: assistant.id)

        let client = LLMClientFactory.make(protocol: provider.apiProtocol, baseURL: provider.baseURL, apiKey: provider.apiKey)
        let allowed = ThinkingCapabilities.levels(provider: provider, model: conversation.model)
        let level = ThinkingCapabilities.effective(conversation.thinking, budget: conversation.thinkingBudget, allowed: allowed)
        var effort: String?
        var budget: Int?
        if provider.apiProtocol.isAnthropic {
            if level == .custom {
                budget = max(1024, conversation.thinkingBudget)
            } else {
                budget = level.anthropicBudget
            }
        } else {
            effort = level.openAIEffort
        }
        let settings = GenerationSettings(
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            temperature: conversation.useTemperature ? conversation.temperature : nil,
            maxTokens: max(16, conversation.maxTokens),
            effort: effort,
            thinkingBudget: budget,
            tools: conversation.webSearchEnabled ? [ToolSpec.webSearch] : []
        )
        let initialMessages = buildNeutralMessages(conversation)

        let task = Task { [weak self] in
            var neutral = initialMessages
            var currentSettings = settings
            var fallbackAttempts = 0
            var errorText: String?
            do {
                var round = 0
                while true {
                    try Task.checkCancellation()
                    round += 1
                    var turnSettings = currentSettings
                    if round > ChatEngine.maxToolRounds { turnSettings.tools = [] }
                    var result = TurnResult()
                    while true {
                        do {
                            result = try await client.streamTurn(messages: neutral, settings: turnSettings) { event in
                                self?.apply(event, to: convID)
                            }
                            break
                        } catch {
                            guard fallbackAttempts < 2,
                                  let notice = ChatEngine.adjustAfterError(error, settings: &turnSettings) else {
                                throw error
                            }
                            fallbackAttempts += 1
                            currentSettings.effort = turnSettings.effort
                            currentSettings.thinkingBudget = turnSettings.thinkingBudget
                            currentSettings.maxTokens = turnSettings.maxTokens
                            self?.addNotice(notice, to: convID)
                        }
                    }
                    if result.toolCalls.isEmpty || turnSettings.tools.isEmpty {
                        break
                    }
                    neutral.append(.assistant(text: result.text, toolCalls: result.toolCalls, rawBlocks: result.rawBlocks))
                    for call in result.toolCalls {
                        try Task.checkCancellation()
                        let output = await self?.runTool(call, convID: convID) ?? ""
                        neutral.append(.toolResult(callID: call.id, name: call.name, content: output))
                    }
                    self?.apply(.text("\n\n"), to: convID, separatorOnly: true)
                }
            } catch is CancellationError {
                // stopped by user
            } catch let urlError as URLError where urlError.code == .cancelled {
                // stopped by user
            } catch {
                errorText = error.localizedDescription
            }
            self?.finish(convID: convID, message: assistant, errorText: errorText, context: context)
        }
        tasks[convID] = task
    }

    private func apply(_ event: StreamEvent, to convID: UUID, separatorOnly: Bool = false) {
        guard var state = streams[convID] else { return }
        switch event {
        case .text(let t):
            if separatorOnly {
                if !state.text.isEmpty && !state.text.hasSuffix("\n\n") { state.text += t }
            } else {
                state.text += t
            }
            state.status = ""
        case .reasoning(let r):
            state.reasoning += r
        }
        streams[convID] = state
    }

    private func addNotice(_ notice: String, to convID: UUID) {
        guard var state = streams[convID] else { return }
        state.notice = state.notice.isEmpty ? notice : state.notice + "\n" + notice
        streams[convID] = state
    }

    /// Adjusts settings after a recoverable API error. Returns a user-facing notice, or nil if not recoverable.
    static func adjustAfterError(_ error: Error, settings: inout GenerationSettings) -> String? {
        var message = ""
        var status = 0
        if let e = error as? LLMError {
            switch e {
            case .http(let code, let body):
                status = code
                message = body
            case .api(let msg):
                message = msg
            default:
                return nil
            }
        } else {
            return nil
        }
        if status != 0 && status != 400 && status != 422 { return nil }
        let lower = message.lowercased()

        // OpenAI: "xhigh" not accepted -> retry with "high".
        if settings.effort == "xhigh",
           lower.contains("xhigh") || lower.contains("effort") || lower.contains("reasoning") {
            settings.effort = "high"
            return String(localized: "当前模型不支持 xhigh,已自动降为 high 重试。")
        }

        // Anthropic: max_tokens above the model's output limit -> clamp budget and max_tokens.
        if let budget = settings.thinkingBudget, lower.contains("max_tokens") {
            if let limit = parseTokenLimit(message), limit > 2048 {
                settings.maxTokens = limit
                settings.thinkingBudget = min(budget, limit - 2048)
                return String(localized: "思考预算超过模型输出上限,已自动调整为 \(limit - 2048) 并重试。")
            }
        }
        return nil
    }

    /// Extracts N from messages like "max_tokens: 68096 > 64000, which is the maximum allowed".
    static func parseTokenLimit(_ message: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: ">\\s*([0-9]+)") else { return nil }
        let ns = message as NSString
        guard let m = re.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 else {
            return nil
        }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private func runTool(_ call: ToolCall, convID: UUID) async -> String {
        guard call.name == ToolSpec.webSearch.name else {
            return "Unknown tool: \(call.name)"
        }
        let args = HTTP.parse(call.arguments) ?? [:]
        let query = ((args["query"] as? String) ?? call.arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        if var state = streams[convID] {
            state.toolLog += "🔍 \(query)\n"
            state.status = String(localized: "正在搜索…")
            streams[convID] = state
        }
        do {
            let results = try await WebSearchService.search(query)
            if var state = streams[convID] {
                for r in results.prefix(5) {
                    state.toolLog += "   • [\(r.title)](\(r.url))\n"
                }
                state.status = ""
                streams[convID] = state
            }
            return WebSearchService.format(results, query: query)
        } catch {
            if var state = streams[convID] {
                state.toolLog += "   ⚠️ \(error.localizedDescription)\n"
                state.status = ""
                streams[convID] = state
            }
            return "Search failed: \(error.localizedDescription)"
        }
    }

    private func finish(convID: UUID, message: ChatMessage, errorText: String?, context: ModelContext) {
        let state = streams[convID]
        streams[convID] = nil
        tasks[convID] = nil
        if message.isDeleted || message.modelContext == nil {
            return
        }
        var text = (state?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = errorText {
            message.isError = true
            text = text.isEmpty ? err : text + "\n\n⚠️ " + err
        }
        message.content = text
        message.reasoning = state?.reasoning ?? ""
        message.toolLog = state?.toolLog ?? ""
        message.notice = state?.notice ?? ""
        message.conversation?.updatedAt = Date()
        try? context.save()
    }
}
