import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var engine: ChatEngine
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selectedID: UUID?
    var newChat: () -> Void
    @Binding var showSettings: Bool
    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return conversations }
        return conversations.filter { conv in
            conv.title.localizedCaseInsensitiveContains(q)
                || conv.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        List(selection: $selectedID) {
            ForEach(filtered) { conv in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(conv.displayTitle)
                            .lineLimit(1)
                            .font(.body)
                        if engine.isGenerating(conv) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    HStack {
                        Text(conv.model.isEmpty ? String(localized: "未选择模型") : conv.model)
                            .lineLimit(1)
                        Spacer()
                        Text(conv.updatedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(conv.id)
                .contextMenu {
                    Button {
                        renameText = conv.title
                        renaming = conv
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        delete(conv)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        delete(conv)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: Text("搜索对话"))
        .navigationTitle("OmniChat")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newChat()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .alert("重命名对话", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                renaming?.title = renameText
                try? context.save()
                renaming = nil
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("暂无对话", systemImage: "bubble.left", description: Text("点击右上角新建对话"))
            }
        }
    }

    private func delete(_ conv: Conversation) {
        engine.stop(conv)
        if selectedID == conv.id { selectedID = nil }
        context.delete(conv)
        try? context.save()
    }
}
