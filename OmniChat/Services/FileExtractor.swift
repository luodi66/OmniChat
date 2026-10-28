import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum FileExtractor {
    static let maxTextLength = 200_000

    static func attachment(from url: URL) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .image) {
            let data = try Data(contentsOf: url)
            if let att = imageAttachment(data: data, filename: filename) { return att }
            throw LLMError.api(String(localized: "无法读取图片: ") + filename)
        }

        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else {
                throw LLMError.api(String(localized: "无法读取 PDF: ") + filename)
            }
            var text = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string {
                    text += "\n--- Page \(i + 1) ---\n" + s
                }
                if text.count > maxTextLength { break }
            }
            return Attachment(kind: .text, filename: filename, mimeType: "application/pdf", data: nil, text: truncate(text))
        }

        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) {
            if looksBinary(s) {
                throw LLMError.api(String(localized: "不支持的文件类型: ") + filename)
            }
            return Attachment(kind: .text, filename: filename, mimeType: type.preferredMIMEType ?? "text/plain", data: nil, text: truncate(s))
        }
        throw LLMError.api(String(localized: "不支持的文件类型: ") + filename)
    }

    static func imageAttachment(data: Data, filename: String) -> Attachment? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = downscale(image, maxDimension: 1568)
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return Attachment(kind: .image, filename: filename, mimeType: "image/jpeg", data: jpeg, text: nil)
    }

    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private static func truncate(_ s: String) -> String {
        if s.count <= maxTextLength { return s }
        return String(s.prefix(maxTextLength)) + "\n…[truncated]"
    }

    private static func looksBinary(_ s: String) -> Bool {
        let sample = s.prefix(2000)
        var control = 0
        for scalar in sample.unicodeScalars {
            if scalar.value < 9 || (scalar.value > 13 && scalar.value < 32) { control += 1 }
        }
        return sample.count > 0 && Double(control) / Double(sample.count) > 0.05
    }
}
