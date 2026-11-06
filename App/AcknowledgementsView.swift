import AppKit
import SwiftUI

/// The Acknowledgements window that About opens: the bundled third-party notices,
/// rendered from their Markdown into a scrollable, selectable text view. It is an
/// `NSTextView`, like a document's, so the whole file selects and copies at once
/// and its links stay clickable.
internal struct AcknowledgementsView: View {
    /// The window's size when it opens. The view sizes to its minimum, so the
    /// window asks for this one; the user can resize it from there. It is wide
    /// enough for an 80-column license in a code block to keep its line breaks.
    static let openingSize = NSSize(width: 600, height: 560)
    private static let repositoryCopyURL =
        URL(string: "https://github.com/steelbrain/LemurCam/blob/main/ACKNOWLEDGEMENTS.md")

    private let notices: NSAttributedString?

    /// `markdown` is the notices file's text, or nil when it couldn't be read.
    init(markdown: String?) {
        notices = markdown.map { AcknowledgementsText.render(Acknowledgements.blocks(in: $0)) }
    }

    var body: some View {
        Group {
            if let notices {
                NoticesTextView(text: notices)
            } else {
                missingNotices
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }

    private var missingNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LemurCam couldn’t read its acknowledgements file.")
                .font(.headline)
            if let url = Self.repositoryCopyURL {
                Link("Read the acknowledgements on GitHub", destination: url)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A read-only, selectable text view in a scroll view. Its colors are the system's
/// dynamic ones, so it follows light and dark appearance.
private struct NoticesTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 18, height: 18)
            textView.textStorage?.setAttributedString(text)
        }
        return scrollView
    }

    func updateNSView(_: NSScrollView, context _: Context) {}
}

/// Styles the notices' Markdown blocks: system-font headings by level, body-font
/// paragraphs with their inline links and emphasis, and monospaced code blocks.
internal enum AcknowledgementsText {
    private static var bodyFont: NSFont { .preferredFont(forTextStyle: .body) }
    private static let blockSpacing: CGFloat = 10

    static func render(_ blocks: [Acknowledgements.Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if result.length > 0 {
                // The break takes the font and paragraph style of the line it ends,
                // but not a link that ends that line.
                var attributes = result.attributes(at: result.length - 1, effectiveRange: nil)
                attributes[.link] = nil
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            switch block {
            case let .heading(level, text):
                result.append(inline(text, font: headingFont(level: level), spacingBefore: index > 0 ? 8 : 0))
            case .paragraph(let text):
                result.append(inline(text, font: bodyFont, spacingBefore: 0))
            case .code(let text):
                result.append(code(text))
            }
        }
        return result
    }

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .bold)
        case 2: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .bold)
        case 3: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
        default: .systemFont(ofSize: bodyFont.pointSize, weight: .semibold)
        }
    }

    private static func paragraphStyle(spacingBefore: CGFloat, spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }

    /// One paragraph, with Markdown's inline syntax applied: links stay clickable,
    /// and strong, emphasized and code spans get bold, italic and monospaced fonts.
    private static func inline(_ markdown: String, font: NSFont, spacingBefore: CGFloat) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        let style = paragraphStyle(spacingBefore: spacingBefore, spacingAfter: blockSpacing)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: styled(font, for: run.inlinePresentationIntent),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func styled(_ font: NSFont, for intent: InlinePresentationIntent?) -> NSFont {
        guard let intent else { return font }
        if intent.contains(.code) {
            return .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }

    /// A code block's lines in a monospaced font, spaced as one block: only its last
    /// line carries the gap to the next block.
    private static func code(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 2, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            result.append(NSAttributedString(
                string: isLast ? line : line + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle(spacingBefore: 0, spacingAfter: isLast ? blockSpacing : 0)
                ]
            ))
        }
        return result
    }
}
