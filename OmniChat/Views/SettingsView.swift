import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @AppStorage(WebSearchService.backendDefaultsKey) private var searchBackend: String = SearchBackend.auto.rawValue
    @AppStorage(WebSearchService.resultCountKey) private var resultCount: Int = 5
    @AppStorage("defaultSystemPrompt") private var defaultSystemPrompt: String = ""
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("defaultThinking") private var defaultThinking: String = ThinkingLevel.off.rawValue
    @AppStorage("defaultThinkingBudget") private var defaultThinkingBudget: Int = 16000
    @State private var tavilyKey: String = WebSearchService.tavilyKey
    @State private var editingProvider: ProviderConfig?
    @State private var addingProvider = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(providers) { p in
                        Button {
                            editingProvider = p
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("\(p.apiProtocol.displayName) · \(p.models.count) models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let p = providers[i]
                            KeychainStore.delete("provider.\(p.id.uuidString)")
                            context.delete(p)
                        }
                        try? context.save()
                    }
                    Button {
                        addingProvider = true
                    } label: {
                        Label("添加服务商", systemImage: "plus")
                    }
                } header: {
                    Text("API 服务商")
                } footer: {
                    Text("API Key 仅保存在本机钥匙串中,请求直接发送到你填写的地址。")
                }

                Section {
                    Picker("搜索后端", selection: $searchBackend) {
                        ForEach(SearchBackend.allCases) { b in
                            Text(b.displayName).tag(b.rawValue)
                        }
                    }
                    SecureField("Tavily API Key (可选)", text: $tavilyKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: tavilyKey) {
                            WebSearchService.tavilyKey = tavilyKey
                        }
                    Stepper(value: $resultCount, in: 1...10) {
                        Text("结果数量: \(resultCount)")
                    }
                } header: {
                    Text("联网搜索")
                } footer: {
                    Text("Tavily 需要 API Key(tavily.com 免费额度);DuckDuckGo 无需 Key,但稳定性较差。")
                }

                Section("默认值") {
                    VStack(alignment: .leading) {
                        Text("新对话的系统提示词")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $defaultSystemPrompt)
                            .frame(minHeight: 80)
                    }
                    Picker(selection: $defaultThinking) {
                        ForEach(ThinkingLevel.ordered) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                        Text(ThinkingLevel.custom.title).tag(ThinkingLevel.custom.rawValue)
                    } label: {
                        Label("默认思考程度", systemImage: "brain.head.profile")
                    }
                    if defaultThinking == ThinkingLevel.custom.rawValue {
                        Stepper(value: $defaultThinkingBudget, in: 1024...128000, step: 1024) {
                            Text(verbatim: "budget_tokens: \(defaultThinkingBudget)")
                        }
                    }
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    Link("GitHub: luodi66/OmniChat", destination: URL(string: "https://github.com/luodi66/OmniChat")!)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingProvider) { p in
                ProviderEditView(provider: p)
            }
            .sheet(isPresented: $addingProvider) {
                ProviderEditView(provider: nil)
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

struct ProviderEditView: View {
    let provider: ProviderConfig?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var apiProtocol: APIProtocol = .openAIChat
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var levelOverrides: [String: [String]] = [:]
    @State private var newModel = ""
    @State private var fetching = false
    @State private var message: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称,例如 OpenAI / 我的中转", text: $name)
                    Picker("协议", selection: $apiProtocol) {
                        ForEach(APIProtocol.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(models, id: \.self) { m in
                        NavigationLink {
                            ModelCapabilityView(model: m, apiProtocol: apiProtocol, overrides: $levelOverrides)
                        } label: {
                            HStack {
                                Text(m)
                                Spacer()
                                Text(levelSummary(for: m))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { models.remove(atOffsets: $0) }
                    HStack {
                        TextField("添加模型 ID", text: $newModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addModel)
                        Button("添加", action: addModel)
                            .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Label("从服务器获取模型列表", systemImage: "arrow.down.circle")
                            if fetching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(fetching || baseURL.isEmpty)
                    if !models.isEmpty {
                        Button("清空模型列表", role: .destructive) { models = [] }
                    }
                } header: {
                    Text("模型 (\(models.count))")
                } footer: {
                    if let message = message {
                        Text(message)
                    }
                }
            }
            .navigationTitle(provider == nil ? "添加服务商" : "编辑服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.isEmpty)
                }
            }
            .onAppear(perform: load)
            .onChange(of: apiProtocol) { oldValue, newValue in
                if baseURL.isEmpty || baseURL == oldValue.defaultBaseURL {
                    baseURL = newValue.defaultBaseURL
                }
            }
        }
    }

    private var hint: String {
        switch apiProtocol {
        case .openAIChat:
            return String(localized: "请求地址: {Base URL}/chat/completions。Base URL 通常以 /v1 结尾,例如 https://api.openai.com/v1、https://api.deepseek.com/v1、https://openrouter.ai/api/v1。")
        case .openAIResponses:
            return String(localized: "请求地址: {Base URL}/responses(OpenAI 新版 Responses API)。")
        case .anthropic:
            return String(localized: "请求地址: {Base URL}/v1/messages(若 Base URL 已以 /v1 结尾则直接拼接 /messages)。例如 https://api.anthropic.com。")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let p = provider {
            name = p.name
            apiProtocol = p.apiProtocol
            baseURL = p.baseURL
            apiKey = p.apiKey
            models = p.models
            levelOverrides = p.levelOverrides
        } else {
            baseURL = apiProtocol.defaultBaseURL
        }
    }

    private func levelSummary(for model: String) -> String {
        let levels: [ThinkingLevel]
        if let o = levelOverrides[model] {
            levels = o.compactMap { ThinkingLevel(rawValue: $0) }.sorted { $0.rank < $1.rank }
        } else {
            levels = ThinkingCapabilities.autoLevels(protocol: apiProtocol, model: model)
        }
        let names = levels.filter { $0 != .off }.map { $0.title }
        let prefix = levelOverrides[model] == nil ? String(localized: "自动") : String(localized: "自定义")
        if names.isEmpty { return prefix + " · " + ThinkingLevel.off.title }
        return prefix + " · " + names.joined(separator: "/")
    }

    private func addModel() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        if !models.contains(m) { models.append(m) }
        newModel = ""
    }

    private func fetchModels() async {
        fetching = true
        message = nil
        defer { fetching = false }
        let client = LLMClientFactory.make(protocol: apiProtocol, baseURL: baseURL, apiKey: apiKey)
        do {
            let fetched = try await client.listModels()
            var merged = models
            for m in fetched where !merged.contains(m) { merged.append(m) }
            models = merged
            message = String(localized: "获取到 \(fetched.count) 个模型")
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() {
        let target: ProviderConfig
        if let p = provider {
            target = p
        } else {
            target = ProviderConfig(name: name, apiProtocol: apiProtocol, baseURL: baseURL)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.apiProtocol = apiProtocol
        target.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        target.models = models
        target.levelOverrides = levelOverrides.filter { models.contains($0.key) }
        target.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        dismiss()
    }
}
