import Foundation
import SwiftData
import SwiftUI

struct StreamState {
    var messageID: UUID
    var text: String = ""
    var reasoning: String = ""
    var toolLog: String = ""
    var status: String = ""
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
        let settings = GenerationSettings(
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            temperature: conversation.useTemperature ? conversation.temperature : nil,
            maxTokens: max(16, conversation.maxTokens),
            thinkingLevel: conversation.thinkingLevel,
            thinkingBudget: conversation.thinkingBudget,
            tools: conversation.webSearchEnabled ? [ToolSpec.webSearch] : []
        )
        let initialMessages = buildNeutralMessages(conversation)

        let task = Task { [weak self] in
            var neutral = initialMessages
            var errorText: String?
            do {
                var round = 0
                while true {
                    try Task.checkCancellation()
                    round += 1
                    var turnSettings = settings
                    if round > ChatEngine.maxToolRounds { turnSettings.tools = [] }
                    let result = try await client.streamTurn(messages: neutral, settings: turnSettings) { event in
                        self?.apply(event, to: convID)
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
        message.conversation?.updatedAt = Date()
        try? context.save()
    }
}
