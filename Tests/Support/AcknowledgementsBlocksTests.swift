@testable import LemurCam
import XCTest

/// Pins how the notices' Markdown splits into blocks for the Acknowledgements
/// window: headings by level, paragraphs whose wrapped lines join as Markdown
/// renders them, and code blocks kept line for line.
internal final class AcknowledgementsBlocksTests: XCTestCase {
    func testHeadingsParagraphsAndCodeBlocksSplit() {
        let markdown = """
        # Acknowledgements

        ## Retina

        IPCamKit started out as a port of
        [Retina](https://example.com/retina), an RTSP library.

        ```
        The MIT License (MIT)
          Indented line
        ```

        ### Next
        Text under the heading.
        """
        XCTAssertEqual(Acknowledgements.blocks(in: markdown), [
            .heading(level: 1, text: "Acknowledgements"),
            .heading(level: 2, text: "Retina"),
            .paragraph("IPCamKit started out as a port of [Retina](https://example.com/retina), an RTSP library."),
            .code("The MIT License (MIT)\n  Indented line"),
            .heading(level: 3, text: "Next"),
            .paragraph("Text under the heading.")
        ])
    }

    func testMarksWithoutASpaceAreText() {
        XCTAssertEqual(Acknowledgements.blocks(in: "#tag\n####### seven"), [.paragraph("#tag ####### seven")])
    }

    func testAnUnclosedCodeBlockKeepsItsLines() {
        XCTAssertEqual(Acknowledgements.blocks(in: "Before\n```\none\ntwo"), [
            .paragraph("Before"),
            .code("one\ntwo")
        ])
    }

    func testBlankTextHasNoBlocks() {
        XCTAssertEqual(Acknowledgements.blocks(in: "\n  \n"), [])
    }
}
