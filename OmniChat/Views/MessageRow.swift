import SwiftUI
import UIKit

struct MessageRow: View {
    let message: ChatMessage
    let stream: StreamState?
    let isLast: Bool
    let canAct: Bool
    var onRegenerate: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var text: String { stream?.text ?? message.content }
    private var reasoning: String { stream?.reasoning ?? message.reasoning }
    private var toolLog: String { stream?.toolLog ?? message.toolLog }
    private var notice: String { stream?.notice ?? message.notice }

    var body: some View {
        if message.isUser {
            userBody
        } else {
            assistantBody
        }
    }

    private var userBody: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                let atts = message.attachments
                if !atts.isEmpty {
                    AttachmentStrip(attachments: atts, onRemove: nil)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if canAct {
                Button {
                    onEdit()
                } label: {
                    Label("编辑并重新发送", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(message.modelName.isEmpty ? "Assistant" : message.modelName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !reasoning.isEmpty {
                ThinkingBlock(text: reasoning, isStreaming: stream != nil && text.isEmpty)
            }
            if !notice.isEmpty {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !toolLog.isEmpty {
                ToolLogBlock(text: toolLog)
            }
            if let status = stream?.status, !status.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            if stream != nil && text.isEmpty && reasoning.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
            if !text.isEmpty {
                if message.isError {
                    Text(text)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    MarkdownView(text: text)
                }
            }
            if stream == nil {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(Text("复制"))
                    if isLast && canAct {
                        Button {
                            onRegenerate()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(Text("重新生成"))
                    }
                    if canAct {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Text("删除"))
                    }
                }
                .buttonStyle(.borderless)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if isLast && canAct {
                Button {
                    onRegenerate()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

struct ThinkingBlock: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text(isStreaming ? "思考中…" : "思考过程")
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ToolLogBlock: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(MarkdownParser.inline(text))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("联网搜索", systemImage: "globe")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct AttachmentStrip: View {
    let attachments: [Attachment]
    var onRemove: ((Attachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    ZStack(alignment: .topTrailing) {
                        chip(att)
                        if let onRemove = onRemove {
                            Button {
                                onRemove(att)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private func chip(_ att: Attachment) -> some View {
        if att.kind == .image, let data = att.data, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text(att.filename)
                        .lineLimit(1)
                        .font(.caption)
                    Text("\((att.text ?? "").count) chars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: 200, minHeight: 48)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
