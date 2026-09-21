import XCTest
@testable import Halo

final class HaloMarkdownTests: XCTestCase {
    func testStrongEmphasisRendersWithoutMarkdownDelimiters() {
        let rendered = HaloMarkdown.attributedString(from: "Keep **this bold**.")

        XCTAssertEqual(String(rendered.characters), "Keep this bold.")
        let boldRun = rendered.runs.first { String(rendered[$0.range].characters) == "this bold" }
        XCTAssertEqual(boldRun?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testLinksKeepTheirLabelAndClickableURL() {
        let rendered = HaloMarkdown.attributedString(
            from: "Open [the docs](https://example.com/guide) next."
        )

        XCTAssertEqual(String(rendered.characters), "Open the docs next.")
        guard let linkRun = rendered.runs.first(where: { $0.link != nil }) else {
            XCTFail("Expected the Markdown link to retain a clickable URL")
            return
        }
        XCTAssertEqual(linkRun.link, URL(string: "https://example.com/guide"))
        XCTAssertEqual(String(rendered[linkRun.range].characters), "the docs")
    }

    func testOtherInlineFormattingAndWhitespaceArePreserved() {
        let rendered = HaloMarkdown.attributedString(
            from: "*italic* `code` ~~removed~~\nsecond line"
        )

        XCTAssertEqual(String(rendered.characters), "italic code removed\nsecond line")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent == .emphasized })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent == .code })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent == .strikethrough })
    }

    func testMarkdownCanBeDisabledForLiteralToolContent() {
        let rendered = HaloMarkdown.attributedString(
            from: "**swift test**",
            interpretsMarkdown: false
        )

        XCTAssertEqual(String(rendered.characters), "**swift test**")
        XCTAssertFalse(rendered.runs.contains { $0.inlinePresentationIntent != nil })
    }
}
