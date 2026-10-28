import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @State private var selectedID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showSettings = false
    @AppStorage("lastProviderID") private var lastProviderID: String = ""
    @AppStorage("lastModel") private var lastModel: String = ""
    @AppStorage("defaultSystemPrompt") private var defaultSystemPrompt: String = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedID: $selectedID, newChat: newChat, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            if let id = selectedID, let conversation = conversations.first(where: { $0.id == id }) {
                ChatView(conversation: conversation, newChat: newChat)
                    .id(conversation.id)
            } else {
                EmptyDetailView(hasProviders: !providers.isEmpty, newChat: newChat, showSettings: $showSettings)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    func newChat() {
        let conv = Conversation()
        let lastID = UUID(uuidString: lastProviderID)
        let provider = providers.first(where: { $0.id == lastID }) ?? providers.first
        if let p = provider {
            conv.providerID = p.id
            if p.id == lastID, !lastModel.isEmpty {
                conv.model = lastModel
            } else {
                conv.model = p.models.first ?? ""
            }
        }
        conv.systemPrompt = defaultSystemPrompt
        context.insert(conv)
        try? context.save()
        selectedID = conv.id
    }
}

struct EmptyDetailView: View {
    var hasProviders: Bool
    var newChat: () -> Void
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("OmniChat")
                .font(.largeTitle.bold())
            if hasProviders {
                Text("选择或新建一个对话开始聊天")
                    .foregroundStyle(.secondary)
                Button {
                    newChat()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("先添加一个 API 服务商(OpenAI 或 Anthropic 协议)")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showSettings = true
                } label: {
                    Label("添加服务商", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
