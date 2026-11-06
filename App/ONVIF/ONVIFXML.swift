import Foundation
import XMLKit

/// The single entry point for parsing XML that arrives from the network.
///
/// XMLKit builds its tree with one recursive call per nesting level, so a reply of a
/// few KB of nested tags overflows the stack of the thread that parses it. Any host on
/// the LAN can answer a WS-Discovery probe, and every saved ONVIF camera is contacted
/// at launch, so a hostile document would crash the app on every launch. `parse` caps
/// the document size and measures element nesting with an iterative scan before XMLKit
/// sees the text, and rejects anything over the limits.
internal enum ONVIFXML {
    /// Largest document accepted, in bytes. A GetProfiles reply from a 64-channel
    /// recorder is well under 1 MB; WS-Discovery replies fit in one UDP datagram.
    static let maxDocumentBytes = 2 * 1024 * 1024

    /// Deepest element nesting accepted. SOAP replies from cameras nest about 10 to
    /// 15 levels; XMLKit's recursion stays far from the stack limit at this depth.
    static let maxElementDepth = 64

    enum Rejection: LocalizedError, Equatable {
        case tooLarge
        case tooDeep
        case unsupportedMarkup
        case malformed

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The camera's response is too large"
            case .tooDeep: return "The camera's response is nested too deeply"
            case .unsupportedMarkup: return "The camera's response contains a document type declaration"
            case .malformed: return "The camera's response is not valid XML"
            }
        }
    }

    /// Bytes that are not valid UTF-8 are read as ISO Latin-1, which some cameras
    /// use for device names, rather than failing the whole response.
    static func parse(_ data: Data) throws -> XMLKit.XMLElement {
        guard data.count <= maxDocumentBytes else { throw Rejection.tooLarge }
        let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
        return try parseChecked(text)
    }

    static func parse(_ text: String) throws -> XMLKit.XMLElement {
        guard text.utf8.count <= maxDocumentBytes else { throw Rejection.tooLarge }
        return try parseChecked(text)
    }

    private static func parseChecked(_ text: String) throws -> XMLKit.XMLElement {
        try checkStructure(text)
        return try XMLKit.XMLElement.parse(text)
    }

    /// Throws unless every element in `text` nests at most `maxDepth` levels deep.
    ///
    /// The scan walks the same `Character` sequence XMLKit's tokenizer walks and
    /// recognizes markup the same way (comments, CDATA, processing instructions, end
    /// tags, quoted attribute values), so for any document XMLKit accepts the depth
    /// measured here equals the depth XMLKit recurses to. Where the two could differ
    /// (input XMLKit rejects anyway) the scan errs toward a higher depth. Stray end
    /// tags never drive the depth below zero, because XMLKit ignores them at the top
    /// level. DTDs are rejected outright: SOAP 1.2 forbids them in messages.
    static func checkStructure(_ text: String, maxDepth: Int = maxElementDepth) throws {
        let chars = Array(text)
        var index = 0
        var depth = 0
        while index < chars.count {
            guard chars[index] == "<" else {
                index += 1
                continue
            }
            let markup = try scanMarkup(in: chars, at: index)
            index = markup.next
            depth = max(0, depth + markup.depthChange)
            if depth > maxDepth { throw Rejection.tooDeep }
        }
    }

    /// Classifies the markup starting at the `<` at `index`, in the order XMLKit's
    /// tokenizer checks, and returns where it ends and how it changes the depth.
    private static func scanMarkup(in chars: [Character], at index: Int) throws -> (next: Int, depthChange: Int) {
        if hasPrefix(chars, at: index, Markup.commentOpen) {
            return (try end(of: Markup.commentClose, in: chars, from: index + Markup.commentOpen.count), 0)
        }
        if hasPrefix(chars, at: index, Markup.cdataOpen) {
            return (try end(of: Markup.cdataClose, in: chars, from: index + Markup.cdataOpen.count), 0)
        }
        if hasPrefix(chars, at: index, Markup.declarationOpen) {
            throw Rejection.unsupportedMarkup
        }
        if hasPrefix(chars, at: index, Markup.instructionOpen) {
            return (try end(of: Markup.instructionClose, in: chars, from: index + 2), 0)
        }
        if hasPrefix(chars, at: index, Markup.endTagOpen) {
            return (try end(of: Markup.tagClose, in: chars, from: index + 2), -1)
        }
        let tag = try endOfStartTag(in: chars, from: index + 1)
        return (tag.next, tag.selfClosing ? 0 : 1)
    }

    private enum Markup {
        static let commentOpen = Array("<!--")
        static let commentClose = Array("-->")
        static let cdataOpen = Array("<![CDATA[")
        static let cdataClose = Array("]]>")
        static let declarationOpen = Array("<!")
        static let instructionOpen = Array("<?")
        static let instructionClose = Array("?>")
        static let endTagOpen = Array("</")
        static let tagClose = Array(">")
    }

    private static func hasPrefix(_ chars: [Character], at index: Int, _ prefix: [Character]) -> Bool {
        guard index + prefix.count <= chars.count else { return false }
        for offset in prefix.indices where chars[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    /// Index just past the first occurrence of `terminator` at or after `start`.
    private static func end(of terminator: [Character], in chars: [Character], from start: Int) throws -> Int {
        var index = start
        while index < chars.count {
            if hasPrefix(chars, at: index, terminator) { return index + terminator.count }
            index += 1
        }
        throw Rejection.malformed
    }

    /// Finds the `>` that closes a start tag, skipping quoted attribute values (which
    /// may contain `>`), and reports whether the tag closed with `/>`.
    private static func endOfStartTag(in chars: [Character], from start: Int) throws -> (next: Int, selfClosing: Bool) {
        var quote: Character?
        var index = start
        while index < chars.count {
            let char = chars[index]
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ">" {
                let selfClosing = index > start && chars[index - 1] == "/"
                return (index + 1, selfClosing)
            }
            index += 1
        }
        throw Rejection.malformed
    }
}
