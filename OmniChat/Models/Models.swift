import Foundation
import SwiftData

enum APIProtocol: String, CaseIterable, Identifiable, Codable {
    case openAIChat = "openai_chat"
    case openAIResponses = "openai_responses"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChat: return String(localized: "OpenAI 兼容 (Chat Completions)")
        case .openAIResponses: return String(localized: "OpenAI Responses")
        case .anthropic: return String(localized: "Anthropic Messages")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAIChat, .openAIResponses: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    var isAnthropic: Bool { self == .anthropic }
}

@Model
final class ProviderConfig {
    var id: UUID = UUID()
    var name: String = ""
    var protocolRaw: String = APIProtocol.openAIChat.rawValue
    var baseURL: String = ""
    var models: [String] = []
    var createdAt: Date = Date()
    /// JSON: [modelID: [ThinkingLevel.rawValue]] — user overrides of supported thinking levels.
    var modelLevelOverridesJSON: String = ""

    init(name: String, apiProtocol: APIProtocol, baseURL: String, models: [String] = []) {
        self.id = UUID()
        self.name = name
        self.protocolRaw = apiProtocol.rawValue
        self.baseURL = baseURL
        self.models = models
        self.createdAt = Date()
    }

    var apiProtocol: APIProtocol {
        get { APIProtocol(rawValue: protocolRaw) ?? .openAIChat }
        set { protocolRaw = newValue.rawValue }
    }

    var levelOverrides: [String: [String]] {
        get {
            guard let data = modelLevelOverridesJSON.data(using: .utf8), !modelLevelOverridesJSON.isEmpty else { return [:] }
            return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
        }
        set {
            if newValue.isEmpty {
                modelLevelOverridesJSON = ""
            } else if let data = try? JSONEncoder().encode(newValue) {
                modelLevelOverridesJSON = String(data: data, encoding: .utf8) ?? ""
            }
        }
    }

    var apiKey: String {
        get { KeychainStore.get("provider.\(id.uuidString)") ?? "" }
        set { KeychainStore.set(newValue, for: "provider.\(id.uuidString)") }
    }
}

@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var providerID: UUID?
    var model: String = ""
    var systemPrompt: String = ""
    var useTemperature: Bool = false
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    /// Legacy (v0.1): 0 = off, 1 = low, 2 = medium, 3 = high. Superseded by thinkingRaw.
    var thinkingLevel: Int = 0
    /// ThinkingLevel.rawValue; empty means "use legacy thinkingLevel".
    var thinkingRaw: String = ""
    /// Anthropic budget_tokens used by the "custom" level.
    var thinkingBudget: Int = 16000
    var webSearchEnabled: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(title: String = "") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.createdAt < b.createdAt
        }
    }

    var nextOrder: Int {
        (messages.map { $0.order }.max() ?? -1) + 1
    }

    var thinking: ThinkingLevel {
        get {
            if let level = ThinkingLevel(rawValue: thinkingRaw) { return level }
            return ThinkingLevel.fromLegacy(thinkingLevel)
        }
        set {
            thinkingRaw = newValue.rawValue
        }
    }

    var displayTitle: String {
        title.isEmpty ? String(localized: "新对话") : title
    }
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: String = "user"
    var content: String = ""
    var reasoning: String = ""
    var toolLog: String = ""
    var notice: String = ""
    var modelName: String = ""
    var isError: Bool = false
    var order: Int = 0
    var createdAt: Date = Date()
    @Attribute(.externalStorage) var attachmentsData: Data?
    var conversation: Conversation?

    init(role: String, content: String, order: Int, attachments: [Attachment] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.order = order
        self.createdAt = Date()
        self.attachments = attachments
    }

    var isUser: Bool { role == "user" }

    var attachments: [Attachment] {
        get {
            guard let data = attachmentsData else { return [] }
            return (try? JSONDecoder().decode([Attachment].self, from: data)) ?? []
        }
        set {
            attachmentsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }
}

struct Attachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case text
    }

    var id: UUID = UUID()
    var kind: Kind
    var filename: String
    var mimeType: String
    var data: Data?
    var text: String?
}
