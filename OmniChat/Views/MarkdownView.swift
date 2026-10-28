import SwiftUI
import UIKit

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case bullet(Int, String)
    case numbered(Int, String, String)
    case quote(String)
    case table(String)
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                blocks.append(.table(table.joined(separator: "\n")))
                table = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        let lines = text.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
                    inCode = false
                    codeLines = []
                    codeLang = ""
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushAll()
                inCode = true
                codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushQuote()
                table.append(trimmed)
                continue
            } else {
                flushTable()
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(hashes, rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var q = String(trimmed.dropFirst())
                if q.hasPrefix(" ") { q.removeFirst() }
                quote.append(q)
                continue
            } else {
                flushQuote()
            }

            let indent = (line.prefix(while: { $0 == " " }).count) / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(indent, String(trimmed.dropFirst(2))))
                continue
            }

            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
                let num = trimmed[trimmed.startIndex..<dot]
                let after = trimmed[trimmed.index(after: dot)...]
                if !num.isEmpty, num.count <= 3, num.allSatisfy({ $0.isNumber }), after.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.numbered(indent, String(num), after.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }

            paragraph.append(line)
        }

        if inCode {
            blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let a = try? AttributedString(markdown: s, options: options) {
            return a
        }
        return AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownParser.inline(s))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(MarkdownParser.inline(s))
                .font(headingFont(level))
                .fontWeight(.bold)
                .padding(.top, 4)
        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code)
        case .bullet(let indent, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: indent > 0 ? "◦" : "•")
                Text(MarkdownParser.inline(s))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let num, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: num + ".")
                    .monospacedDigit()
                Text(MarkdownParser.inline(s))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let s):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(MarkdownParser.inline(s))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let s):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: s)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}
