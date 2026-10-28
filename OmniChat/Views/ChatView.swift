import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var conversation: Conversation
    var newChat: () -> Void

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var engine: ChatEngine
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @AppStorage("lastProviderID") private var lastProviderID: String = ""
    @AppStorage("lastModel") private var lastModel: String = ""

    @State private var showOptions = false
    @State private var editingMessage: ChatMessage?
    @State private var editText = ""
    @State private var showExporter = false
    @State private var exportDocument = MarkdownFile(text: "")

    private var provider: ProviderConfig? {
        providers.first(where: { $0.id == conversation.providerID })
    }

    var body: some View {
        let messages = conversation.sortedMessages
        let stream = engine.streamState(for: conversation)
        messageList(messages: messages, stream: stream)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(conversation: conversation, provider: provider)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(generating: stream != nil, isEmpty: messages.isEmpty) }
        .sheet(isPresented: $showOptions) {
            ChatOptionsView(conversation: conversation)
        }
        .sheet(item: $editingMessage) { message in
            EditMessageSheet(text: $editText) {
                engine.edit(message, newText: editText, in: conversation, context: context)
                editingMessage = nil
            } onCancel: {
                editingMessage = nil
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in }
    }

    @ToolbarContentBuilder
    private func toolbarContent(generating: Bool, isEmpty: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            modelMenu
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ShareLink(item: ConversationExporter.markdown(conversation), subject: Text(conversation.displayTitle)) {
                    Label("分享为文本", systemImage: "square.and.arrow.up")
                }
                Button {
                    exportDocument = MarkdownFile(text: ConversationExporter.markdown(conversation))
                    showExporter = true
                } label: {
                    Label("导出 Markdown 文件", systemImage: "doc.richtext")
                }
                Button {
                    exportDocument = MarkdownFile(text: ConversationExporter.json(conversation))
                    showExporter = true
                } label: {
                    Label("导出 JSON 文件", systemImage: "curlybraces")
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            Button {
                showOptions = true
            } label: {
                Label("对话设置", systemImage: "slider.horizontal.3")
            }
            .keyboardShortcut("k", modifiers: .command)
            Button {
                engine.regenerate(in: conversation, context: context)
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(generating || isEmpty)
        }
    }

    private func messageList(messages: [ChatMessage], stream: StreamState?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty {
                        emptyHint
                    }
                    ForEach(messages) { message in
                        row(for: message, messages: messages, stream: stream)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: scrollKey(stream)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func scrollKey(_ stream: StreamState?) -> Int {
        guard let s = stream else { return 0 }
        return s.text.count + s.reasoning.count / 200 + s.toolLog.count
    }

    private func row(for message: ChatMessage, messages: [ChatMessage], stream: StreamState?) -> MessageRow {
        let isStreamingRow = stream?.messageID == message.id
        return MessageRow(
            message: message,
            stream: isStreamingRow ? stream : nil,
            isLast: message.id == messages.last?.id,
            canAct: stream == nil,
            onRegenerate: { engine.regenerate(in: conversation, context: context) },
            onEdit: {
                editText = message.content
                editingMessage = message
            },
            onDelete: {
                engine.delete(message, from: conversation, context: context)
                try? context.save()
            }
        )
    }

    private var exportFilename: String {
        let base = conversation.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let ext = exportDocument.text.hasPrefix("{") ? "json" : "md"
        return "\(base).\(ext)"
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if provider == nil {
                Text("还没有选择服务商")
                    .font(.headline)
                Button("打开对话设置") { showOptions = true }
                    .buttonStyle(.bordered)
            } else {
                Text(conversation.model.isEmpty ? String(localized: "请选择模型") : conversation.model)
                    .font(.headline)
                Text(provider?.name ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var modelMenu: some View {
        Menu {
            if providers.isEmpty {
                Text("请先在设置中添加服务商")
            }
            ForEach(providers) { p in
                Section(p.name) {
                    if p.models.isEmpty {
                        Text("该服务商没有模型,请在设置中添加")
                    }
                    ForEach(p.models, id: \.self) { model in
                        Button {
                            select(provider: p, model: model)
                        } label: {
                            if conversation.providerID == p.id && conversation.model == model {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 0) {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Text(conversation.model.isEmpty ? String(localized: "选择模型") : conversation.model)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
        }
    }

    private func select(provider p: ProviderConfig, model: String) {
        conversation.providerID = p.id
        conversation.model = model
        lastProviderID = p.id.uuidString
        lastModel = model
        try? context.save()
    }
}

struct EditMessageSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存并重新生成", action: onSave)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
        }
    }
}

struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum ConversationExporter {
    static func markdown(_ conversation: Conversation) -> String {
        var out = "# \(conversation.displayTitle)\n\n"
        if !conversation.model.isEmpty { out += "_Model: \(conversation.model)_\n\n" }
        if !conversation.systemPrompt.isEmpty {
            out += "> System: \(conversation.systemPrompt.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
        for m in conversation.sortedMessages {
            out += m.isUser ? "## 🧑 User\n\n" : "## 🤖 Assistant\(m.modelName.isEmpty ? "" : " (\(m.modelName))")\n\n"
            for att in m.attachments {
                out += "📎 \(att.filename)\n\n"
            }
            if !m.reasoning.isEmpty {
                out += "<details><summary>Thinking</summary>\n\n\(m.reasoning)\n\n</details>\n\n"
            }
            out += m.content + "\n\n"
        }
        return out
    }

    static func json(_ conversation: Conversation) -> String {
        let messages: [[String: Any]] = conversation.sortedMessages.map { m in
            var d: [String: Any] = [
                "role": m.role,
                "content": m.content,
                "created_at": ISO8601DateFormatter().string(from: m.createdAt)
            ]
            if !m.reasoning.isEmpty { d["reasoning"] = m.reasoning }
            if !m.modelName.isEmpty { d["model"] = m.modelName }
            let files = m.attachments.map { $0.filename }
            if !files.isEmpty { d["attachments"] = files }
            return d
        }
        let obj: [String: Any] = [
            "title": conversation.displayTitle,
            "model": conversation.model,
            "system_prompt": conversation.systemPrompt,
            "messages": messages
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
