import SwiftUI

/// Small intensity meter (bars that fill up with the level).
struct IntensityBars: View {
    let level: ThinkingLevel

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(fill(for: i))
                    .frame(width: 3, height: CGFloat(4 + i * 2))
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(for i: Int) -> Color {
        let active: Int
        if level == .custom {
            active = 4
        } else {
            active = level.rank
        }
        if i <= active {
            return ThinkingLevel.color(intensity: Double(i - 1) / 5.0)
        }
        return Color.secondary.opacity(0.25)
    }
}

/// Compact pill shown in the composer; opens a popover (iPad) / sheet (iPhone).
struct ThinkingPill: View {
    @Bindable var conversation: Conversation
    let provider: ProviderConfig?
    @State private var showPanel = false

    private var allowed: [ThinkingLevel] {
        ThinkingCapabilities.levels(provider: provider, model: conversation.model)
    }

    private var effective: ThinkingLevel {
        ThinkingCapabilities.effective(conversation.thinking, budget: conversation.thinkingBudget, allowed: allowed)
    }

    private var tint: Color {
        effective == .custom ? ThinkingLevel.color(forBudget: conversation.thinkingBudget) : effective.color
    }

    private var label: String {
        if effective == .custom { return "\(conversation.thinkingBudget / 1000)k" }
        return effective.title
    }

    var body: some View {
        Button {
            showPanel = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: effective == .off ? "brain" : "brain.head.profile")
                    .font(.footnote.weight(.semibold))
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                IntensityBars(level: effective)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(effective == .off ? Color.secondary : tint)
            .background(Capsule().fill(effective == .off ? Color(.tertiarySystemFill) : tint.opacity(0.14)))
            .overlay(Capsule().stroke(effective == .off ? Color.clear : tint.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("思考程度"))
        .accessibilityValue(Text(effective.title))
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            ThinkingPanel(conversation: conversation, provider: provider, showsHeader: true)
                .frame(minWidth: 340, idealWidth: 400)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
        }
    }
}

/// Discrete stepped slider with labels, gradient track and haptics.
struct LevelStepSlider: View {
    let levels: [ThinkingLevel]
    @Binding var selection: ThinkingLevel
    var dimmed: Bool = false

    private let inset: CGFloat = 16
    private let trackY: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let count = max(levels.count - 1, 1)
            let step = (width - inset * 2) / CGFloat(count)
            let index = levels.firstIndex(of: selection) ?? 0
            ZStack(alignment: .topLeading) {
                track(width: width, filledWidth: step * CGFloat(index))
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    Circle()
                        .fill(i <= index && !dimmed ? stepColor(i) : Color(.systemGray4))
                        .frame(width: 8, height: 8)
                        .position(x: inset + step * CGFloat(i), y: trackY)
                    Text(level.stepLabel)
                        .font(.caption2.weight(i == index ? .bold : .regular))
                        .foregroundStyle(i == index && !dimmed ? stepColor(i) : Color.secondary)
                        .fixedSize()
                        .position(x: inset + step * CGFloat(i), y: trackY + 24)
                }
                Circle()
                    .fill(Color(.systemBackground))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(dimmed ? Color(.systemGray3) : stepColor(index), lineWidth: 4))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .position(x: inset + step * CGFloat(index), y: trackY)
                    .animation(.spring(response: 0.28, dampingFraction: 0.8), value: index)
            }
            .frame(width: width, height: 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = (value.location.x - inset) / step
                        let i = min(max(Int(raw.rounded()), 0), levels.count - 1)
                        if levels[i] != selection {
                            selection = levels[i]
                        }
                    }
            )
        }
        .frame(height: 52)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement()
        .accessibilityLabel(Text("思考程度"))
        .accessibilityValue(Text(selection.title))
        .accessibilityAdjustableAction { direction in
            guard let i = levels.firstIndex(of: selection) else { return }
            switch direction {
            case .increment:
                if i + 1 < levels.count { selection = levels[i + 1] }
            case .decrement:
                if i > 0 { selection = levels[i - 1] }
            @unknown default:
                break
            }
        }
    }

    private func stepColor(_ i: Int) -> Color {
        guard i >= 0, i < levels.count else { return .secondary }
        let level = levels[i]
        return level == .off ? Color.secondary : level.color
    }

    private var gradientColors: [Color] {
        let colored = levels.filter { $0 != .off }.map { $0.color }
        if colored.isEmpty { return [Color.secondary, Color.secondary] }
        if colored.count == 1 { return [colored[0], colored[0]] }
        return colored
    }

    @ViewBuilder
    private func track(width: CGFloat, filledWidth: CGFloat) -> some View {
        let trackWidth = max(width - inset * 2, 1)
        Capsule()
            .fill(Color(.systemGray5))
            .frame(width: trackWidth, height: 6)
            .position(x: width / 2, y: trackY)
        Capsule()
            .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
            .frame(width: trackWidth, height: 6)
            .mask(alignment: .leading) {
                Rectangle().frame(width: filledWidth)
            }
            .opacity(dimmed ? 0.35 : 1)
            .position(x: width / 2, y: trackY)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: filledWidth)
    }
}

/// Full thinking control: header, stepped slider, description, custom budget, auto-adapt note.
struct ThinkingPanel: View {
    @Bindable var conversation: Conversation
    let provider: ProviderConfig?
    var showsHeader: Bool = true
    @Environment(\.dismiss) private var dismiss

    private var allowed: [ThinkingLevel] {
        ThinkingCapabilities.levels(provider: provider, model: conversation.model)
    }

    private var stepLevels: [ThinkingLevel] {
        allowed.filter { $0 != .custom }
    }

    private var effective: ThinkingLevel {
        ThinkingCapabilities.effective(conversation.thinking, budget: conversation.thinkingBudget, allowed: allowed)
    }

    private var tint: Color {
        effective == .custom ? ThinkingLevel.color(forBudget: conversation.thinkingBudget) : effective.color
    }

    private var sliderBinding: Binding<ThinkingLevel> {
        Binding(
            get: {
                let e = effective
                if e == .custom {
                    return ThinkingCapabilities.effective(ThinkingLevel.nearest(budget: conversation.thinkingBudget), budget: 0, allowed: stepLevels)
                }
                return e
            },
            set: { conversation.thinking = $0 }
        )
    }

    private var customBinding: Binding<Bool> {
        Binding(
            get: { effective == .custom },
            set: { on in
                if on {
                    if let b = effective.anthropicBudget { conversation.thinkingBudget = b }
                    conversation.thinking = .custom
                } else {
                    conversation.thinking = ThinkingCapabilities.effective(ThinkingLevel.nearest(budget: conversation.thinkingBudget), budget: 0, allowed: stepLevels)
                }
            }
        )
    }

    private var budgetBinding: Binding<Double> {
        Binding(
            get: { Double(conversation.thinkingBudget) },
            set: { conversation.thinkingBudget = Int($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                header
            }

            if stepLevels.count > 1 {
                LevelStepSlider(levels: stepLevels, selection: sliderBinding, dimmed: effective == .custom)
                    .padding(.horizontal, 2)
            } else {
                Label("当前模型不支持思考参数。可在服务商的模型设置中手动开启。", systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            descriptionCard

            if allowed.contains(.custom) {
                customSection
            }

            if conversation.thinking != effective && conversation.thinking != .custom {
                Label("当前模型不支持「\(conversation.thinking.title)」,已自动使用「\(effective.title)」。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Label("自动适配模型:仅显示当前模型支持的档位。可在「设置 → 服务商 → 模型」中自定义。", systemImage: "wand.and.stars")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsHeader {
                Spacer(minLength: 0)
            }
        }
        .padding(showsHeader ? 20 : 0)
        .animation(.easeInOut(duration: 0.2), value: effective)
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: customBinding) {
                Label("自定义预算", systemImage: "slider.horizontal.below.rectangle")
            }
            .tint(tint)
            if effective == .custom {
                HStack {
                    Slider(value: budgetBinding, in: ThinkingCapabilities.customBudgetRange, step: 1024)
                        .tint(tint)
                    Text(verbatim: "\(conversation.thinkingBudget)")
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .sensoryFeedback(.selection, trigger: conversation.thinkingBudget / 8192)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(effective == .off ? 0.12 : 0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: effective == .off ? "brain" : "brain.head.profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(effective == .off ? Color.secondary : tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("思考程度")
                    .font(.headline)
                Text(conversation.model.isEmpty ? String(localized: "未选择模型") : conversation.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(effective.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(effective == .off ? Color.secondary : tint)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("完成"))
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IntensityBars(level: effective)
                Text(effective.title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(effective.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: ThinkingCapabilities.parameterDescription(effective, budget: conversation.thinkingBudget, protocol: provider?.apiProtocol))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(effective == .off ? Color(.secondarySystemBackground) : tint.opacity(0.10))
        )
    }
}

/// Per-model override of supported thinking levels (used in provider settings).
struct ModelCapabilityView: View {
    let model: String
    let apiProtocol: APIProtocol
    @Binding var overrides: [String: [String]]

    private var autoLevels: [ThinkingLevel] {
        ThinkingCapabilities.autoLevels(protocol: apiProtocol, model: model)
    }

    private var candidates: [ThinkingLevel] {
        var list: [ThinkingLevel] = [.minimal, .low, .medium, .high, .xhigh, .max]
        if apiProtocol.isAnthropic { list.append(.custom) }
        return list
    }

    private var isAuto: Binding<Bool> {
        Binding(
            get: { overrides[model] == nil },
            set: { auto in
                if auto {
                    overrides[model] = nil
                } else {
                    overrides[model] = autoLevels.map { $0.rawValue }
                }
            }
        )
    }

    private func levelBinding(_ level: ThinkingLevel) -> Binding<Bool> {
        Binding(
            get: {
                if let o = overrides[model] { return o.contains(level.rawValue) }
                return autoLevels.contains(level)
            },
            set: { on in
                var current = overrides[model] ?? autoLevels.map { $0.rawValue }
                current.removeAll { $0 == level.rawValue }
                if on { current.append(level.rawValue) }
                overrides[model] = current
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("自动 (根据模型名推断)", isOn: isAuto)
            } footer: {
                Text("自动模式下:gpt-5 系列支持 minimal~xhigh;o 系列等推理模型支持 low/medium/high;gpt-4 等非推理模型关闭思考;Anthropic 支持全部档位(Claude 3/3.5 除外)。")
            }
            Section {
                ForEach(candidates) { level in
                    Toggle(isOn: levelBinding(level)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                IntensityBars(level: level)
                                Text(level.title)
                            }
                            Text(verbatim: ThinkingCapabilities.parameterDescription(level, budget: 16000, protocol: apiProtocol))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(overrides[model] == nil)
                }
            } header: {
                Text("支持的思考档位")
            }
        }
        .navigationTitle(model)
        .navigationBarTitleDisplayMode(.inline)
    }
}
