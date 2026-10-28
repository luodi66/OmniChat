import SwiftUI
import PhotosUI
import SwiftData
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var conversation: Conversation
    let isAnthropic: Bool
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.modelContext) private var context

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var generating: Bool { engine.isGenerating(conversation) }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { att in
                    attachments.removeAll { $0.id == att.id }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("文件 (文本 / PDF / 图片)", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(Text("添加附件"))

                Button {
                    conversation.webSearchEnabled.toggle()
                } label: {
                    Image(systemName: "globe")
                        .font(.title3)
                        .foregroundStyle(conversation.webSearchEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("联网搜索"))

                ThinkingMenu(conversation: conversation, isAnthropic: isAnthropic)

                TextField("输入消息…", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .focused($focused)

                if generating {
                    Button {
                        engine.stop(conversation)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel(Text("停止"))
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(Text("发送"))
                }
            }
            if conversation.webSearchEnabled || conversation.thinkingLevel > 0 {
                HStack(spacing: 12) {
                    if conversation.webSearchEnabled {
                        Label("联网搜索已开启", systemImage: "globe")
                    }
                    if conversation.thinkingLevel > 0 {
                        Label(ThinkingMapping.summary(conversation, isAnthropic: isAnthropic), systemImage: "brain.head.profile")
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) {
            loadPhotos()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do {
                        attachments.append(try FileExtractor.attachment(from: url))
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for (i, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let att = FileExtractor.imageAttachment(data: data, filename: "photo-\(i + 1).jpg") {
                    attachments.append(att)
                }
            }
        }
    }

    private func send() {
        guard canSend, !generating else { return }
        engine.send(text: text, attachments: attachments, in: conversation, context: context)
        text = ""
        attachments = []
    }
}
