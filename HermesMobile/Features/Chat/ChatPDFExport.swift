import SwiftUI
import UIKit

/// PDF export of a whole chat or a selection (requirement 6), ported from JARVIS v2's
/// ChatExportEngine + ChatPDFRenderer onto Hermex's `ChatMessage`: cover, running header, page
/// numbers, one block per message. Rich blocks print their text form (`fallbackText`), voice
/// notes print their transcript, and tool or system rows are left out.
enum ChatPDFExport {
    struct Options: Equatable {
        var includeCover = true
        var includeHeaders = true
        var includePageNumbers = true
        var includeTimestamps = true
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let isUser: Bool
        let date: Date?
        let text: String
    }

    /// The exportable messages, oldest first: user and assistant rows with something to print.
    static func entries(from messages: [ChatMessage]) -> [Entry] {
        messages.compactMap { message in
            let role = message.role ?? ""
            guard role == "user" || role == "assistant" else { return nil }
            let text = printableText(message)
            guard !text.isEmpty else { return nil }
            return Entry(id: message.id, isUser: role == "user",
                         date: message.timestamp.map { Date(timeIntervalSince1970: $0) }, text: text)
        }
    }

    static func printableText(_ message: ChatMessage) -> String {
        let content = MessageAttachment.contentWithoutAttachedFilesMarker(in: message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isVoiceNote = (message.attachments ?? []).contains { VoiceNoteFilename.isVoiceNoteAttachment($0.name ?? $0.path) }
        if isVoiceNote { return content.isEmpty ? "Voice note" : "Voice note: \(content)" }
        guard let parts = RichMessageSegments.split(content) else { return content }
        return parts.map { part -> String in
            switch part {
            case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .rich(let blocks, _): return blocks.map(\.fallbackText).joined(separator: "\n")
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Writes the PDF to a temporary file and returns its URL.
    static func render(title: String, entries: [Entry], options: Options) throws -> URL {
        let pageWidth: CGFloat = 612, pageHeight: CGFloat = 792, margin: CGFloat = 56
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "JARVIS"]
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let content = bounds.insetBy(dx: margin, dy: margin)
        let small = UIFont.systemFont(ofSize: 8)
        let header = "Enrique Alonso · \(title) · \(Date().formatted(date: .abbreviated, time: .omitted))"

        let data = renderer.pdfData { context in
            var page = 0
            var y = content.minY
            var started = false

            func newPage() {
                context.beginPage()
                page += 1
                y = content.minY
                if options.includeHeaders {
                    header.draw(in: CGRect(x: margin, y: 28, width: content.width, height: 14),
                                withAttributes: [.font: small, .foregroundColor: UIColor.gray])
                }
                if options.includePageNumbers {
                    "Page \(page)".draw(in: CGRect(x: margin, y: pageHeight - 34, width: content.width, height: 14),
                                        withAttributes: [.font: small, .foregroundColor: UIColor.gray])
                }
            }

            func paragraph(_ text: String, font: UIFont, color: UIColor) {
                let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                // Long messages break across pages paragraph by paragraph.
                for chunk in text.isEmpty ? [""] : attributed.string.components(separatedBy: "\n\n") {
                    let piece = NSAttributedString(string: chunk, attributes: [.font: font, .foregroundColor: color])
                    let height = piece.boundingRect(with: CGSize(width: content.width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                    if !started || y + height > content.maxY { newPage(); started = true }
                    piece.draw(with: CGRect(x: content.minX, y: y, width: content.width, height: height),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    y += height + 6
                }
            }

            if options.includeCover {
                context.beginPage()
                page += 1
                ("JARVIS · Chat export" as NSString).draw(at: CGPoint(x: margin, y: 180), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.gray])
                title.draw(in: CGRect(x: margin, y: 210, width: content.width, height: 120), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor.black])
                let dates = entries.compactMap(\.date)
                var line = "\(entries.count) messages"
                if let first = dates.min(), let last = dates.max() {
                    line += " · \(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
                }
                line.draw(at: CGPoint(x: margin, y: 350), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.gray])
            }

            for entry in entries {
                var label = entry.isUser ? "Enrique" : "JARVIS"
                if options.includeTimestamps, let date = entry.date {
                    label += " · " + date.formatted(date: .abbreviated, time: .shortened)
                }
                paragraph(label, font: .boldSystemFont(ofSize: 9),
                          color: entry.isUser ? UIColor(JarvisBrand.deepTeal) : .darkGray)
                paragraph(entry.text, font: .systemFont(ofSize: 11), color: .black)
                y += 8
            }
            if !started && !options.includeCover { newPage() }
        }

        let safeTitle = title.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JARVIS - \(safeTitle).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Export to PDF: the whole chat or the messages you pick, with the cover/header/page-number options.
struct ChatPDFExportSheet: View {
    let title: String
    let entries: [ChatPDFExport.Entry]
    @Environment(\.dismiss) private var dismiss
    @State private var options = ChatPDFExport.Options()
    @State private var selectsMessages = false
    @State private var selected: Set<String> = []
    @State private var shareURL: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Export", selection: $selectsMessages) {
                        Text("Whole chat").tag(false)
                        Text("Selected messages").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if selectsMessages {
                    Section {
                        ForEach(entries) { entry in
                            Button {
                                if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: entry.isUser ? "Enrique" : "JARVIS").font(.caption.weight(.semibold))
                                        Text(verbatim: entry.text).font(.footnote).lineLimit(3).foregroundStyle(.primary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(verbatim: "\(selected.count) of \(entries.count)")
                            Spacer()
                            Button(selected.count == entries.count ? "Select None" : "Select All") {
                                selected = selected.count == entries.count ? [] : Set(entries.map(\.id))
                            }
                            .font(.caption)
                        }
                    }
                }
                Section {
                    Toggle("Cover page", isOn: $options.includeCover)
                    Toggle("Header", isOn: $options.includeHeaders)
                    Toggle("Page numbers", isOn: $options.includePageNumbers)
                    Toggle("Timestamps", isOn: $options.includeTimestamps)
                }
                if let errorText {
                    Section { Text(verbatim: errorText).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        export()
                    } label: {
                        Label("Create PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                    }
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("export.createPDF")
                }
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: Binding(get: { shareURL.map(SessionExportShareItem.init(fileURL:)) },
                                 set: { if $0 == nil { shareURL = nil } })) { item in
                SessionExportShareSheet(fileURL: item.fileURL)
            }
        }
    }

    private var chosen: [ChatPDFExport.Entry] {
        selectsMessages ? entries.filter { selected.contains($0.id) } : entries
    }

    private func export() {
        do {
            shareURL = try ChatPDFExport.render(title: title, entries: chosen, options: options)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
