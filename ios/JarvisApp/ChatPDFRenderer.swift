import UIKit
import Persistence
import FeaturesChat

/// Item 13: UIKit PDF renderer — turns the engine's `ExportDocument` into a
/// real PDF file (cover, headers, footers with page numbers, message blocks).
/// App-target only (UIKit); the package side stays macOS-lane safe.
enum ChatPDFRenderer {

    struct Metrics {
        static let margin: CGFloat = 56
        static let pageWidth: CGFloat = 612   // US Letter @72dpi
        static let pageHeight: CGFloat = 792
    }

    /// Render and write the PDF to a temporary file. Returns the file URL.
    static func render(document: ChatExportEngine.ExportDocument,
                       options: ChatExportEngine.Options) throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: document.title,
            kCGPDFContextCreator as String: "JARVIS",
        ]
        let bounds = CGRect(x: 0, y: 0,
                            width: Metrics.pageWidth,
                            height: Metrics.pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        var pageNumber = 0
        var header: String?

        let data = renderer.pdfData { ctx in
            // Cover
            if options.includeCover {
                ctx.beginPage()
                pageNumber += 1
                drawCover(document: document, in: ctx.cgContext)
            }

            // Message pages
            let bodyFont = UIFont.systemFont(ofSize: 11)
            let roleFont = UIFont.boldSystemFont(ofSize: 9)
            let lineHeight: CGFloat = 15
            let contentRect = bounds.insetBy(dx: Metrics.margin, dy: Metrics.margin)

            func newPage() {
                ctx.beginPage()
                pageNumber += 1
                if options.includeHeaders, let header {
                    header.draw(
                        in: CGRect(x: Metrics.margin, y: 28,
                                   width: bounds.width - 2 * Metrics.margin, height: 14),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 8),
                            .foregroundColor: UIColor.secondaryLabel,
                        ])
                }
                if options.includePageNumbers {
                    let label = "Page \(pageNumber)"
                    label.draw(
                        in: CGRect(x: Metrics.margin,
                                   y: bounds.height - 34,
                                   width: bounds.width - 2 * Metrics.margin, height: 14),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 8),
                            .foregroundColor: UIColor.secondaryLabel,
                        ])
                }
            }

            var y = contentRect.minY
            var pageStarted = false

            func ensureRoom(_ needed: CGFloat) {
                if !pageStarted {
                    newPage()
                    pageStarted = true
                    y = contentRect.minY
                }
                if y + needed > contentRect.maxY {
                    newPage()
                    y = contentRect.minY
                }
            }

            func drawParagraph(_ text: String, font: UIFont, color: UIColor) {
                let attributed = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ])
                let maxW = contentRect.width
                let rect = attributed.boundingRect(
                    with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil)
                ensureRoom(rect.height + lineHeight * 0.4)
                attributed.draw(with: CGRect(x: contentRect.minX, y: y, width: maxW, height: rect.height),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                context: nil)
                y += rect.height + lineHeight * 0.6
            }

            if options.includeHeaders {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .none
                header = "Enrique Alonso · \(document.title) · \(df.string(from: Date()))"
            }

            for block in document.blocks {
                let roleLabel: String
                let roleColor: UIColor
                switch block.role {
                case .user:
                    roleLabel = "You"
                    roleColor = UIColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 1)
                case .assistant:
                    roleLabel = "JARVIS"
                    roleColor = .darkGray
                case .system, .tool:
                    roleLabel = block.role.rawValue.capitalized
                    roleColor = .secondaryLabel
                }

                var textBody: String
                switch block.kind {
                case .text(let text):
                    textBody = text
                case .omitted(let line):
                    textBody = line
                case .richBlocks(let richBlocks):
                    // Print-policy fidelity (Item 11 contract):
                    // summary → fallbackDisplayText; native text blocks →
                    // textual rendering; snapshot/omit → stable textual
                    // summary line (raster pipeline is a follow-up; text
                    // never lies about what the block held).
                    textBody = richBlocks.map { rich in
                        let strategy = rich.print?.strategy
                            ?? RichPrintDefaults.strategy(for: rich.type)
                        switch strategy {
                        case .summary:
                            return rich.fallbackDisplayText
                        case .native:
                            return rich.displayTextForPrint
                        case .snapshot, .omit:
                            return "[\(rich.type.rawValue) — \(strategy == .omit ? "omitted" : "visual block")]"
                        }
                    }.joined(separator: "\n\n")
                }

                ensureRoom(lineHeight * 2)
                let timeLabel: String
                if options.includeTimestamps {
                    let df = DateFormatter()
                    df.dateStyle = .short
                    df.timeStyle = .short
                    timeLabel = " · \(df.string(from: block.createdAt))"
                } else {
                    timeLabel = ""
                }
                drawParagraph("\(roleLabel)\(timeLabel)", font: roleFont, color: roleColor)
                drawParagraph(textBody, font: bodyFont, color: .label)
                y += lineHeight * 0.4
            }

            if !pageStarted, options.includeCover == false {
                // Document with no body pages can't happen (engine throws
                // noContent) — but never emit an empty PDF regardless.
                newPage()
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-export-\(Int(Date().timeIntervalSince1970)).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func drawCover(document: ChatExportEngine.ExportDocument,
                                  in context: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: Metrics.pageWidth, height: Metrics.pageHeight)
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none

        ("JARVIS — Chat export" as NSString).draw(
            at: CGPoint(x: Metrics.margin, y: 180),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        document.title.draw(
            in: CGRect(x: Metrics.margin, y: 210,
                       width: bounds.width - 2 * Metrics.margin, height: 120),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor.label,
            ])
        let count = "\(document.messageCount) messages · exported \(df.string(from: Date()))"
        count.draw(
            at: CGPoint(x: Metrics.margin, y: 350),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.secondaryLabel,
            ])
    }
}

// MARK: - RichBlock print text

extension RichBlock {
    /// Textual form for `native` print strategy: title + key textual fields.
    /// Charts/tables degrade to their accessible summary; everything else to
    /// fallbackDisplayText — never empty (Item 11 never-blank law).
    var displayTextForPrint: String {
        if let f = fallbackDisplayText, !f.isEmpty { return f }
        return "[\(type.rawValue) block]"
    }
}
