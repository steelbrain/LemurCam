import AppKit
@testable import LemurCam
import XCTest

/// The Acknowledgements window shows the notices rendered, not as Markdown source:
/// no heading marks, link syntax or code fences, with links still clickable and
/// headings set larger than the text.
internal final class AcknowledgementsTextTests: XCTestCase {
    func testTheBundledNoticesRenderWithoutMarkdownSyntax() throws {
        let markdown = try XCTUnwrap(Acknowledgements.load())
        let text = AcknowledgementsText.render(Acknowledgements.blocks(in: markdown)).string
        XCTAssertTrue(text.hasPrefix("Acknowledgements\nUniCamEx\n"))
        XCTAssertTrue(text.contains("NullAudio"))
        for syntax in ["# ", "](", "```"] {
            XCTAssertFalse(text.contains(syntax), "rendered text still contains \(syntax)")
        }
    }

    func testLinksStayLinks() throws {
        let rendered = AcknowledgementsText.render([.paragraph("Uses [IPCamKit](https://example.com/ipcamkit) for RTSP.")])
        XCTAssertEqual(rendered.string, "Uses IPCamKit for RTSP.")
        let start = (rendered.string as NSString).range(of: "IPCamKit").location
        var range = NSRange()
        let link = try XCTUnwrap(rendered.attribute(.link, at: start, effectiveRange: &range) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/ipcamkit")
        XCTAssertEqual(range, NSRange(location: start, length: "IPCamKit".count))
    }

    func testABreakAfterALinkIsNotPartOfIt() {
        let rendered = AcknowledgementsText.render([.paragraph("[A](https://example.com/a)"), .paragraph("B")])
        XCTAssertEqual(rendered.string, "A\nB")
        XCTAssertNil(rendered.attribute(.link, at: 1, effectiveRange: nil))
    }

    func testHeadingsAreLargerThanText() throws {
        let rendered = AcknowledgementsText.render([.heading(level: 2, text: "Retina"), .paragraph("Text")])
        let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let body = try XCTUnwrap(rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
    }

    func testCodeBlocksAreMonospaced() throws {
        let rendered = AcknowledgementsText.render([.code("The MIT License (MIT)\nCopyright")])
        XCTAssertEqual(rendered.string, "The MIT License (MIT)\nCopyright")
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)
    }
}
