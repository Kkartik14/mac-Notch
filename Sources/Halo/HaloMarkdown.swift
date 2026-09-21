import Foundation
import SwiftUI

/// Shared inline-Markdown rendering for assistant replies from developer
/// activity providers. Block-level syntax stays out of this compact chat
/// surface, while whitespace/newlines are preserved exactly.
enum HaloMarkdown {
    static func attributedString(
        from source: String,
        interpretsMarkdown: Bool = true
    ) -> AttributedString {
        guard interpretsMarkdown else { return AttributedString(source) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

/// A small shared view keeps provider chat rows consistent and leaves
/// non-assistant content (especially tool commands) as literal text.
struct HaloMarkdownText: View {
    let text: String
    var interpretsMarkdown = true

    var body: some View {
        Text(HaloMarkdown.attributedString(from: text, interpretsMarkdown: interpretsMarkdown))
            .tint(Color(red: 0.55, green: 0.74, blue: 1.0))
    }
}
