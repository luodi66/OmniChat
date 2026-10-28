import SwiftUI

enum ThinkingMapping {
    static let anthropicPresets: [Int] = [0, 2048, 8192, 24576]
    static let maxBudget: Double = 64000

    static func levelName(_ level: Int) -> String {
        switch level {
        case 1: return String(localized: "低")
        case 2: return String(localized: "中")
        case 3: return String(localized: "高")
        default: return String(localized: "关闭")
        }
    }

    static func level(forBudget budget: Int) -> Int {
        if budget <= 0 { return 0 }
        if budget <= 4096 { return 1 }
        if budget <= 16384 { return 2 }
        return 3
    }

    static func apply(level: Int, to conversation: Conversation, isAnthropic: Bool) {
        conversation.thinkingLevel = level
        if isAnthropic, level > 0, level < anthropicPresets.count {
            conversation.thinkingBudget = anthropicPresets[level]
        }
    }

    static func summary(_ conversation: Conversation, isAnthropic: Bool) -> String {
        if conversation.thinkingLevel == 0 { return levelName(0) }
        if isAnthropic { return "\(conversation.thinkingBudget) tokens" }
        return levelName(conversation.thinkingLevel)
    }
}

/// Compact menu used in the composer.
struct ThinkingMenu: View {
    @Bindable var conversation: Conversation
    let isAnthropic: Bool

    var body: some View {
        Menu {
            ForEach(0..<4, id: \.self) { level in
                Button {
                    ThinkingMapping.apply(level: level, to: conversation, isAnthropic: isAnthropic)
                } label: {
                    if conversation.thinkingLevel == level {
                        Label(title(level), systemImage: "checkmark")
                    } else {
                        Text(title(level))
                    }
                }
            }
        } label: {
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundStyle(conversation.thinkingLevel > 0 ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(Text("思考程度"))
    }

    private func title(_ level: Int) -> String {
        let name = ThinkingMapping.levelName(level)
        if isAnthropic && level > 0 {
            return "\(name) · \(ThinkingMapping.anthropicPresets[level]) tokens"
        }
        if !isAnthropic && level > 0 {
            return "\(name) · reasoning_effort"
        }
        return name
    }
}

/// Full control used in the conversation options sheet.
struct ThinkingSection: View {
    @Bindable var conversation: Conversation
    let isAnthropic: Bool

    var body: some View {
        Section {
            if isAnthropic {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("思考预算")
                        Spacer()
                        Text(conversation.thinkingLevel == 0 ? ThinkingMapping.levelName(0) : "\(conversation.thinkingBudget) tokens")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: budgetBinding, in: 0...ThinkingMapping.maxBudget, step: 1024)
                }
            } else {
                Picker("思考程度", selection: levelBinding) {
                    ForEach(0..<4, id: \.self) { level in
                        Text(ThinkingMapping.levelName(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("思考程度")
        } footer: {
            if isAnthropic {
                Text("Anthropic: thinking.budget_tokens,0 为关闭。开启后温度参数会被忽略,max_tokens 会自动大于预算。")
            } else {
                Text("OpenAI: reasoning_effort (Chat) / reasoning.effort (Responses)。仅推理模型支持,关闭时不发送该参数。")
            }
        }
    }

    private var levelBinding: Binding<Int> {
        Binding(
            get: { conversation.thinkingLevel },
            set: { ThinkingMapping.apply(level: $0, to: conversation, isAnthropic: false) }
        )
    }

    private var budgetBinding: Binding<Double> {
        Binding(
            get: { conversation.thinkingLevel == 0 ? 0 : Double(conversation.thinkingBudget) },
            set: { newValue in
                let v = Int(newValue)
                if v < 1024 {
                    conversation.thinkingLevel = 0
                } else {
                    conversation.thinkingBudget = v
                    conversation.thinkingLevel = ThinkingMapping.level(forBudget: v)
                }
            }
        )
    }
}
