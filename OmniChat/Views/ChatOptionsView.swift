import SwiftUI
import SwiftData

struct ChatOptionsView: View {
    @Bindable var conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @State private var customModel = ""

    private var provider: ProviderConfig? {
        providers.first(where: { $0.id == conversation.providerID })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    Picker("服务商", selection: $conversation.providerID) {
                        Text("未选择").tag(UUID?.none)
                        ForEach(providers) { p in
                            Text(p.name).tag(UUID?.some(p.id))
                        }
                    }
                    if let p = provider {
                        Picker("模型", selection: $conversation.model) {
                            if !p.models.contains(conversation.model) {
                                Text(conversation.model.isEmpty ? String(localized: "未选择") : conversation.model)
                                    .tag(conversation.model)
                            }
                            ForEach(p.models, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        HStack {
                            TextField("手动输入模型 ID", text: $customModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("使用") {
                                let m = customModel.trimmingCharacters(in: .whitespaces)
                                guard !m.isEmpty else { return }
                                conversation.model = m
                                if !p.models.contains(m) { p.models.append(m) }
                                customModel = ""
                            }
                            .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text(p.apiProtocol.displayName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("系统提示词") {
                    TextEditor(text: $conversation.systemPrompt)
                        .frame(minHeight: 100)
                }

                ThinkingSection(conversation: conversation, isAnthropic: provider?.apiProtocol.isAnthropic ?? false)

                Section {
                    Toggle("自定义温度", isOn: $conversation.useTemperature)
                    if conversation.useTemperature {
                        HStack {
                            Slider(value: $conversation.temperature, in: 0...2, step: 0.05)
                            Text(String(format: "%.2f", conversation.temperature))
                                .monospacedDigit()
                                .frame(width: 48)
                        }
                    }
                    HStack {
                        Text("最大输出 Tokens")
                        Spacer()
                        TextField("4096", value: $conversation.maxTokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    Stepper(value: $conversation.maxTokens, in: 256...200_000, step: 1024) {
                        Text(verbatim: "\(conversation.maxTokens)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("参数")
                } footer: {
                    Text("关闭自定义温度时不发送 temperature,使用服务端默认值。推理模型通常不支持温度。")
                }

                Section {
                    Toggle("联网搜索 (web_search 工具)", isOn: $conversation.webSearchEnabled)
                } footer: {
                    Text("开启后模型可调用 web_search 工具,由 App 执行搜索并回传结果。需要模型支持函数调用。搜索后端在“设置”中配置。")
                }
            }
            .navigationTitle("对话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onChange(of: conversation.providerID) {
                if let p = provider, !p.models.contains(conversation.model) {
                    conversation.model = p.models.first ?? ""
                }
            }
        }
    }
}
