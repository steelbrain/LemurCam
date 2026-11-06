import Foundation

/// The third-party notices in the app's resources (ACKNOWLEDGEMENTS.md, which the
/// MIT licenses require in every copy of the software), read for the
/// Acknowledgements window that About opens.
internal enum Acknowledgements {
    /// One Markdown block of the notices file.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        /// A paragraph's text, its wrapped lines joined with a space.
        case paragraph(String)
        /// A fenced code block's lines as written, without the fences.
        case code(String)
    }

    /// The bundled notices, or nil when the resource is missing, unreadable or empty.
    static func load(from bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "ACKNOWLEDGEMENTS", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.allSatisfy(\.isWhitespace)
        else { return nil }
        return text
    }

    /// Splits Markdown into the blocks the notices file uses: ATX headings (`#` to
    /// `######`), fenced code blocks, and paragraphs. A blank line ends a paragraph,
    /// and a paragraph's lines join with a space, the way Markdown renders them.
    /// Inline syntax (links, emphasis) is left in the text for the renderer.
    static func blocks(in markdown: String) -> [Block] {
        var parser = BlockParser()
        for line in markdown.components(separatedBy: .newlines) {
            parser.consume(line)
        }
        return parser.finish()
    }
}

private struct BlockParser {
    private var blocks: [Acknowledgements.Block] = []
    private var paragraph: [String] = []
    /// Whether a code fence is open, and the lines read since it opened.
    private var isInCode = false
    private var codeLines: [String] = []

    mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let isFence = line.hasPrefix("```")
        if isInCode {
            if isFence {
                endCode()
            } else {
                codeLines.append(rawLine)
            }
        } else if isFence {
            endParagraph()
            isInCode = true
        } else if line.isEmpty {
            endParagraph()
        } else if let heading = Self.heading(in: line) {
            endParagraph()
            blocks.append(heading)
        } else {
            paragraph.append(line)
        }
    }

    /// The blocks, with a paragraph or an unclosed code block at the end included.
    mutating func finish() -> [Acknowledgements.Block] {
        if isInCode { endCode() }
        endParagraph()
        return blocks
    }

    private mutating func endCode() {
        blocks.append(.code(codeLines.joined(separator: "\n")))
        codeLines = []
        isInCode = false
    }

    private mutating func endParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: " ")))
        paragraph = []
    }

    /// `## Title` is a level-2 heading; `#tag`, with no space after the marks, is text.
    private static func heading(in line: String) -> Acknowledgements.Block? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }
}
