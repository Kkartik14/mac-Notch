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

    func testFencedCodeBlocksRemoveFenceAndLanguageAndHighlightSwiftTokens() {
        let rendered = HaloMarkdown.attributedString(
            from: "Before\n```swift\nlet greeting = \"hello\"\n```\nAfter"
        )
        let visibleText = String(rendered.characters)

        XCTAssertTrue(visibleText.contains("let greeting = \"hello\""))
        XCTAssertTrue(visibleText.contains("Before"))
        XCTAssertTrue(visibleText.contains("After"))
        XCTAssertFalse(visibleText.contains("```"))
        XCTAssertFalse(visibleText.contains("swift"))

        let keywordRun = rendered.runs.first {
            String(rendered[$0.range].characters) == "let"
        }
        XCTAssertEqual(keywordRun?.foregroundColor, HaloMarkdown.codeKeyword)

        let stringRun = rendered.runs.first {
            String(rendered[$0.range].characters) == "\"hello\""
        }
        XCTAssertEqual(stringRun?.foregroundColor, HaloMarkdown.codeString)
        XCTAssertEqual(stringRun?.font, .system(size: 10, design: .monospaced))
    }

    func testUnclosedCodeFenceIsRenderedAsCodeWhileResponseStreams() {
        let rendered = HaloMarkdown.attributedString(from: "```json\n{\"ready\": true")
        let visibleText = String(rendered.characters)

        XCTAssertEqual(visibleText, "{\"ready\": true")
        XCTAssertFalse(visibleText.contains("```"))
        XCTAssertFalse(visibleText.contains("json"))
        XCTAssertTrue(rendered.runs.contains {
            String(rendered[$0.range].characters) == "true"
                && $0.foregroundColor == HaloMarkdown.codeKeyword
        })
    }

    func testFencedCodeDoesNotInterpretInlineMarkdownInsideTheBlock() {
        let rendered = HaloMarkdown.attributedString(from: "```text\n**not bold**\n```")
        let visibleText = String(rendered.characters)

        XCTAssertTrue(visibleText.contains("**not bold**"))
        XCTAssertFalse(rendered.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    func testWorkspaceFileReferencesBecomeLinksToExistingFiles() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloMarkdown-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("Sources/Halo/Example.swift")
        let rootFile = workspace.appendingPathComponent("Package.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let answer = 42".write(to: file, atomically: true, encoding: .utf8)
        try "let package = true".write(to: rootFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let rendered = HaloMarkdown.attributedString(
            from: "See Sources/Halo/Example.swift:12:3, or \(file.path):8, or Package.swift:9.",
            workspaceRoot: workspace.path
        )
        let links = rendered.runs.filter { $0.link != nil }

        XCTAssertEqual(links.count, 3)
        guard links.count == 3 else { return }
        XCTAssertEqual(String(rendered[links[0].range].characters), "Sources/Halo/Example.swift:12:3")
        XCTAssertEqual(String(rendered[links[1].range].characters), "\(file.path):8")
        XCTAssertEqual(String(rendered[links[2].range].characters), "Package.swift:9")
        XCTAssertEqual(links[0].link, file.standardizedFileURL)
        XCTAssertEqual(links[1].link, file.standardizedFileURL)
        XCTAssertEqual(links[2].link, rootFile.standardizedFileURL)
    }

    func testFileReferencesOutsideWorkspaceAreNotLinked() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloMarkdown-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("Workspace", isDirectory: true)
        let outsideFile = parent.appendingPathComponent("Outside/Example.swift")
        try FileManager.default.createDirectory(
            at: outsideFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "let secret = 1".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: parent) }

        let rendered = HaloMarkdown.attributedString(
            from: "Look at ../Outside/Example.swift:1 or \(outsideFile.path):2",
            workspaceRoot: workspace.path
        )

        XCTAssertFalse(rendered.runs.contains { $0.link != nil })
        XCTAssertTrue(String(rendered.characters).contains("../Outside/Example.swift:1"))
        XCTAssertTrue(String(rendered.characters).contains("\(outsideFile.path):2"))
    }

    func testFileReferenceCannotEscapeWorkspaceThroughSymlink() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloMarkdown-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("Workspace", isDirectory: true)
        let outsideFile = parent.appendingPathComponent("Outside/Example.swift")
        let symlink = workspace.appendingPathComponent("Sources/Halo/Example.swift")
        try FileManager.default.createDirectory(
            at: outsideFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let secret = 1".write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
        defer { try? FileManager.default.removeItem(at: parent) }

        let rendered = HaloMarkdown.attributedString(
            from: "Sources/Halo/Example.swift:1",
            workspaceRoot: workspace.path
        )

        XCTAssertFalse(rendered.runs.contains { $0.link != nil })
    }

    func testInlineCodeFileReferenceRemainsMonospacedAndClickable() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloMarkdown-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("Sources/Halo/Example.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let answer = 42".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let rendered = HaloMarkdown.attributedString(
            from: "Open `Sources/Halo/Example.swift:1`",
            workspaceRoot: workspace.path
        )
        guard let linkRun = rendered.runs.first(where: { $0.link != nil }) else {
            XCTFail("Expected an inline-code file reference to be linked")
            return
        }

        XCTAssertEqual(String(rendered[linkRun.range].characters), "Sources/Halo/Example.swift:1")
        XCTAssertEqual(linkRun.link, file.standardizedFileURL)
        XCTAssertEqual(linkRun.font, .system(size: 10, design: .monospaced))
    }

    func testFencedCodeFileReferencesStayLiteral() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloMarkdown-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("Sources/Halo/Example.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let answer = 42".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let rendered = HaloMarkdown.attributedString(
            from: "```swift\nSources/Halo/Example.swift:2\n```",
            workspaceRoot: workspace.path
        )

        XCTAssertFalse(rendered.runs.contains { $0.link != nil })
        XCTAssertEqual(String(rendered.characters), "Sources/Halo/Example.swift:2\n")
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
