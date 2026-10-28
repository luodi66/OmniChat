import Foundation
import SwiftUI

enum ThinkingLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case custom

    var id: String { rawValue }

    /// Ordered levels shown on the step slider (custom is separate).
    static let ordered: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

    var rank: Int {
        switch self {
        case .off: return 0
        case .minimal: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .xhigh: return 5
        case .max: return 6
        case .custom: return 7
        }
    }

    var title: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .minimal: return String(localized: "极简")
        case .low: return String(localized: "低")
        case .medium: return String(localized: "中")
        case .high: return String(localized: "高")
        case .xhigh: return String(localized: "超高")
        case .max: return String(localized: "最大")
        case .custom: return String(localized: "自定义")
        }
    }

    /// Short label used under the slider steps.
    var stepLabel: String {
        switch self {
        case .off: return String(localized: "关")
        case .minimal: return String(localized: "极简")
        case .low: return String(localized: "低")
        case .medium: return String(localized: "中")
        case .high: return String(localized: "高")
        case .xhigh: return "XHigh"
        case .max: return "Max"
        case .custom: return String(localized: "自定义")
        }
    }

    var detail: String {
        switch self {
        case .off: return String(localized: "不进行额外思考,响应最快。")
        case .minimal: return String(localized: "极少量思考,适合简单问答和改写。")
        case .low: return String(localized: "轻度思考,速度与质量兼顾。")
        case .medium: return String(localized: "适中思考,适合大多数任务。")
        case .high: return String(localized: "深入思考,适合复杂推理、编程和数学。")
        case .xhigh: return String(localized: "超高强度思考,耗时更长,消耗更多 Token。")
        case .max: return String(localized: "最大思考强度。OpenAI 发送 xhigh(不支持时自动降为 high),Anthropic 预算 64000。")
        case .custom: return String(localized: "自定义 Anthropic 思考预算 (budget_tokens)。")
        }
    }

    /// OpenAI reasoning_effort / reasoning.effort value.
    var openAIEffort: String? {
        switch self {
        case .off, .custom: return nil
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max: return "xhigh"
        }
    }

    /// Anthropic thinking.budget_tokens value (custom uses the conversation's budget).
    var anthropicBudget: Int? {
        switch self {
        case .off, .custom: return nil
        case .minimal: return 1024
        case .low: return 4096
        case .medium: return 10000
        case .high: return 24000
        case .xhigh: return 48000
        case .max: return 64000
        }
    }

    /// 0...1 intensity used for colors.
    var intensity: Double {
        switch self {
        case .off: return 0
        case .custom: return 0.6
        default: return Double(rank - 1) / 5.0
        }
    }

    var color: Color {
        if self == .off { return Color.secondary }
        return ThinkingLevel.color(intensity: intensity)
    }

    /// Cool (blue/teal) to warm (orange/red).
    static func color(intensity: Double) -> Color {
        let t = Swift.min(Swift.max(intensity, 0), 1)
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.72, brightness: 0.92)
    }

    static func color(forBudget budget: Int) -> Color {
        color(intensity: nearest(budget: budget).intensity)
    }

    static func fromLegacy(_ value: Int) -> ThinkingLevel {
        switch value {
        case 1: return .low
        case 2: return .medium
        case 3: return .high
        default: return .off
        }
    }

    /// Nearest standard level for an Anthropic budget.
    static func nearest(budget: Int) -> ThinkingLevel {
        if budget <= 0 { return .off }
        var best: ThinkingLevel = .minimal
        var bestDiff = Int.max
        for level in ordered {
            guard let b = level.anthropicBudget else { continue }
            let d = abs(b - budget)
            if d < bestDiff {
                bestDiff = d
                best = level
            }
        }
        return best
    }
}

enum ThinkingCapabilities {
    static let customBudgetRange: ClosedRange<Double> = 1024...128000

    /// Levels inferred from the protocol and model name (always includes .off).
    static func autoLevels(protocol p: APIProtocol, model: String) -> [ThinkingLevel] {
        let m = model.lowercased()
        switch p {
        case .anthropic:
            if m.contains("claude-3-") && !m.contains("3-7") {
                return [.off]
            }
            return [.off, .minimal, .low, .medium, .high, .xhigh, .max, .custom]
        case .openAIChat, .openAIResponses:
            if m.contains("gpt-4") || m.contains("gpt-3.5") || m.contains("chatgpt-4o") {
                return [.off]
            }
            if m.contains("gpt-5") {
                return [.off, .minimal, .low, .medium, .high, .xhigh, .max]
            }
            return [.off, .low, .medium, .high, .max]
        }
    }

    static func levels(provider: ProviderConfig?, model: String) -> [ThinkingLevel] {
        guard let p = provider else { return [.off, .low, .medium, .high, .max] }
        if let override = p.levelOverrides[model] {
            var set = override.compactMap { ThinkingLevel(rawValue: $0) }
            if !set.contains(.off) { set.insert(.off, at: 0) }
            if !p.apiProtocol.isAnthropic { set.removeAll { $0 == .custom } }
            return set.sorted { $0.rank < $1.rank }
        }
        return autoLevels(protocol: p.apiProtocol, model: model)
    }

    /// Picks the closest allowed level (preferring the lower one).
    static func effective(_ level: ThinkingLevel, budget: Int, allowed: [ThinkingLevel]) -> ThinkingLevel {
        if allowed.contains(level) { return level }
        var target = level
        if level == .custom { target = ThinkingLevel.nearest(budget: budget) }
        if allowed.contains(target) { return target }
        let candidates = allowed.filter { $0 != .custom }
        if let lower = candidates.filter({ $0.rank <= target.rank }).max(by: { $0.rank < $1.rank }) {
            return lower
        }
        return candidates.min(by: { $0.rank < $1.rank }) ?? .off
    }

    /// Human-readable request parameter for the given level.
    static func parameterDescription(_ level: ThinkingLevel, budget: Int, protocol p: APIProtocol?) -> String {
        if level == .off { return String(localized: "不发送思考参数") }
        if p?.isAnthropic == true {
            let b = level == .custom ? budget : (level.anthropicBudget ?? 0)
            return "thinking.budget_tokens = \(b)"
        }
        let effort = level.openAIEffort ?? "high"
        let key = p == .openAIResponses ? "reasoning.effort" : "reasoning_effort"
        if level == .max { return "\(key) = \(effort)  (→ high fallback)" }
        return "\(key) = \(effort)"
    }
}
