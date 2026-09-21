import Foundation
import SwiftUI

/// Shared Markdown rendering for assistant replies from developer activity
/// providers, with compact fenced-code highlighting for the chat surface.
enum HaloMarkdown {
    private static let fencedCodeRegex = try? NSRegularExpression(
        pattern: #"(?m)^ {0,3}(`{3,}|~{3,})([^\r\n]*)\r?\n([\s\S]*?)(?:^ {0,3}\1[ \t]*\r?$|\z)"#
    )
    private static let fileReferenceRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_./:+-])(?:/(?:[A-Za-z0-9_.+-]+/)*[A-Za-z0-9_.+-]+|(?:[A-Za-z0-9_.+-]+/)+[A-Za-z0-9_.+-]+|[A-Za-z0-9_.+-]+)\.[A-Za-z0-9]{1,10}(?::[0-9]+(?::[0-9]+)?)?(?!(?:[A-Za-z0-9_/:~-]|\.[A-Za-z0-9]))"#
    )
    private static let markdownLinkRegex = try? NSRegularExpression(
        pattern: #"\[[^\]\n]*\]\([^\n)]*\)|<https?://[^>\n]+>"#
    )
    private static let inlineCodeRegex = try? NSRegularExpression(
        pattern: #"(?<!`)`+[^`\n]*`+(?!`)"#
    )
    private static let numberRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z_$])(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?)(?![A-Za-z_$])"#
    )
    private static let identifierRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z_$][A-Za-z0-9_$]*"#
    )

    static let codeForeground = Color.white.opacity(0.86)
    static let codeBackground = Color.white.opacity(0.06)
    static let codeComment = Color.white.opacity(0.42)
    static let codeString = Color(red: 0.62, green: 0.82, blue: 0.64)
    static let codeKeyword = Color(red: 0.78, green: 0.66, blue: 1.0)
    static let codeNumber = Color(red: 0.96, green: 0.73, blue: 0.53)

    static func attributedString(
        from source: String,
        interpretsMarkdown: Bool = true,
        workspaceRoot: String? = nil
    ) -> AttributedString {
        guard interpretsMarkdown else { return AttributedString(source) }

        var rendered = AttributedString()
        var sourceCursor = source.startIndex
        let fullRange = NSRange(source.startIndex..., in: source)

        for match in Self.fencedCodeRegex?.matches(in: source, range: fullRange) ?? [] {
            guard let wholeRange = Range(match.range, in: source),
                  let codeRange = Range(match.range(at: 3), in: source) else { continue }

            rendered.append(inlineMarkdown(
                String(source[sourceCursor..<wholeRange.lowerBound]),
                workspaceRoot: workspaceRoot
            ))

            let languageInfo = Range(match.range(at: 2), in: source)
                .map { String(source[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let language = languageInfo.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            rendered.append(highlightedCode(String(source[codeRange]), language: language))
            sourceCursor = wholeRange.upperBound
        }

        rendered.append(inlineMarkdown(String(source[sourceCursor...]), workspaceRoot: workspaceRoot))
        return rendered
    }

    private static func inlineMarkdown(_ source: String, workspaceRoot: String?) -> AttributedString {
        let preparation = markdownLinkingFileReferences(in: source, workspaceRoot: workspaceRoot)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var rendered = (try? AttributedString(markdown: preparation.text, options: options))
            ?? AttributedString(preparation.text)
        let fileLinkRanges: [Range<AttributedString.Index>] = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link, preparation.monospacedFileLinks.contains(link) else { return nil }
            return run.range
        }
        for range in fileLinkRanges {
            rendered[range].font = .system(size: 10, design: .monospaced)
        }
        return rendered
    }

    private static func markdownLinkingFileReferences(
        in source: String,
        workspaceRoot: String?
    ) -> (text: String, monospacedFileLinks: Set<URL>) {
        guard let workspaceRoot,
              workspaceRoot.hasPrefix("/"),
              let pathRegex = Self.fileReferenceRegex else { return (source, []) }

        let fullRange = NSRange(source.startIndex..., in: source)
        let markdownLinkRanges = markdownLinkRanges(in: source)
        let inlineCodeRanges = inlineCodeRanges(in: source)
        let matches = pathRegex.matches(in: source, range: fullRange)
        var output = ""
        var cursor = source.startIndex
        var monospacedFileLinks: Set<URL> = []

        for match in matches {
            guard let referenceRange = Range(match.range, in: source),
                  !markdownLinkRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let reference = String(source[referenceRange])
            guard let fileURL = localFileURL(for: reference, workspaceRoot: workspaceRoot) else { continue }

            let inlineCodeRange = inlineCodeRanges.first { NSIntersectionRange($0, match.range).length > 0 }
            let replacementRange: Range<String.Index>
            let linkedLabel: String
            if let inlineCodeRange,
               let codeRange = Range(inlineCodeRange, in: source) {
                let codeSpan = String(source[codeRange])
                let delimiterCount = codeSpan.prefix(while: { $0 == "`" }).count
                let codeContents = codeSpan.dropFirst(delimiterCount).dropLast(delimiterCount)
                guard delimiterCount > 0, String(codeContents) == reference else { continue }
                replacementRange = codeRange
                linkedLabel = "`\(reference)`"
            } else {
                replacementRange = referenceRange
                linkedLabel = reference
            }

            guard replacementRange.lowerBound >= cursor else { continue }
            output += source[cursor..<replacementRange.lowerBound]
            output += "[\(linkedLabel)](\(fileURL.absoluteString))"
            if inlineCodeRange != nil {
                monospacedFileLinks.insert(fileURL)
            }
            cursor = replacementRange.upperBound
        }

        output += source[cursor...]
        return (output, monospacedFileLinks)
    }

    private static func markdownLinkRanges(in source: String) -> [NSRange] {
        guard let regex = Self.markdownLinkRegex else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
    }

    private static func inlineCodeRanges(in source: String) -> [NSRange] {
        guard let regex = Self.inlineCodeRegex else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
    }

    private static func localFileURL(for reference: String, workspaceRoot: String) -> URL? {
        let path = reference.replacingOccurrences(
            of: #":[0-9]+(?::[0-9]+)?$"#,
            with: "",
            options: .regularExpression
        )
        let rootURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : rootURL.appendingPathComponent(path)
        let targetURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix), targetURL.path != rootURL.path else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return targetURL
    }

    private static func highlightedCode(_ source: String, language: String) -> AttributedString {
        var rendered = AttributedString(source)
        guard !rendered.characters.isEmpty else { return rendered }

        let wholeRange = rendered.startIndex..<rendered.endIndex
        rendered[wholeRange].font = .system(size: 10, design: .monospaced)
        rendered[wholeRange].foregroundColor = codeForeground
        rendered[wholeRange].backgroundColor = codeBackground

        let normalizedLanguage = language.lowercased()
        var specialRanges: [NSRange] = []
        let commentPatterns = [
            #"//[^\n]*"#,
            #"/\*[\s\S]*?(?:\*/|\z)"#
        ] + (hashCommentLanguages.contains(normalizedLanguage) ? [#"#[^\n]*"#] : [])
          + (["html", "xml", "svg", "markdown", "md"].contains(normalizedLanguage)
             ? [#"<!--[\s\S]*?(?:-->|\z)"#]
             : [])
          + (["sql", "lua"].contains(normalizedLanguage) ? [#"--[^\n]*"#] : [])

        let stringPatterns = [
            #""(?:\\.|[^"\\])*"?"#,
            #"'(?:\\.|[^'\\])*'?"#,
            #"`(?:\\.|[^`\\])*`?"#
        ]
        let lexicalPattern = (commentPatterns + stringPatterns).joined(separator: "|")
        let tokenRanges = apply(
            regex: try? NSRegularExpression(pattern: lexicalPattern),
            in: source,
            to: &rendered,
            colorForMatch: { match in
                guard let range = Range(match.range, in: source),
                      let first = source[range].first else { return codeComment }
                return ["\"", "'", "`"].contains(String(first)) ? codeString : codeComment
            }
        )
        specialRanges.append(contentsOf: tokenRanges)

        specialRanges.append(contentsOf: apply(
            regex: Self.numberRegex,
            in: source,
            to: &rendered,
            colorForMatch: { _ in codeNumber },
            excluding: specialRanges
        ))

        let keywords = keywordsByLanguage[normalizedLanguage] ?? []
        if !keywords.isEmpty {
            specialRanges.append(contentsOf: apply(
                regex: Self.identifierRegex,
                in: source,
                to: &rendered,
                colorForMatch: { match in
                    guard let range = Range(match.range, in: source),
                          keywords.contains(String(source[range])) else { return nil }
                    return codeKeyword
                },
                excluding: specialRanges
            ))
        }

        return rendered
    }

    private static let hashCommentLanguages: Set<String> = [
        "bash", "sh", "shell", "zsh", "python", "py", "ruby", "rb",
        "yaml", "yml", "toml", "makefile", "dockerfile", "r"
    ]

    private static let keywordsByLanguage: [String: Set<String>] = {
        let swift: Set<String> = [
            "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
            "class", "continue", "defer", "deinit", "do", "else", "enum", "extension",
            "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import",
            "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator",
            "private", "protocol", "public", "repeat", "return", "self", "Self", "static",
            "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
            "typealias", "var", "where", "while"
        ]
        let javascript: Set<String> = [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends", "false",
            "finally", "for", "from", "function", "if", "import", "in", "instanceof",
            "interface", "let", "new", "null", "of", "return", "static", "super", "switch",
            "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while",
            "with", "yield", "type", "enum", "implements", "readonly", "keyof", "as"
        ]
        let python: Set<String> = [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
            "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
            "raise", "return", "True", "try", "while", "with", "yield", "match", "case"
        ]
        let shell: Set<String> = [
            "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function",
            "if", "in", "local", "readonly", "return", "select", "then", "time", "until", "while"
        ]
        let rust: Set<String> = [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
            "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
            "trait", "true", "type", "unsafe", "use", "where", "while"
        ]
        let go: Set<String> = [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
            "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
            "return", "select", "struct", "switch", "type", "var", "true", "false", "nil"
        ]
        let json: Set<String> = ["false", "null", "true"]

        return [
            "swift": swift,
            "javascript": javascript, "js": javascript, "jsx": javascript,
            "typescript": javascript, "ts": javascript, "tsx": javascript,
            "python": python, "py": python,
            "bash": shell, "sh": shell, "shell": shell, "zsh": shell,
            "rust": rust, "rs": rust,
            "go": go,
            "json": json, "jsonc": json
        ]
    }()

    private static func apply(
        regex: NSRegularExpression?,
        in source: String,
        to rendered: inout AttributedString,
        colorForMatch: (NSTextCheckingResult) -> Color?,
        excluding excludedRanges: [NSRange] = []
    ) -> [NSRange] {
        guard let regex else { return [] }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var appliedRanges: [NSRange] = []

        for match in matches {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let color = colorForMatch(match),
                  let sourceRange = Range(match.range, in: source),
                  let lowerBound = AttributedString.Index(sourceRange.lowerBound, within: rendered),
                  let upperBound = AttributedString.Index(sourceRange.upperBound, within: rendered) else { continue }

            rendered[lowerBound..<upperBound].foregroundColor = color
            appliedRanges.append(match.range)
        }

        return appliedRanges
    }
}

/// A small shared view keeps provider chat rows consistent and leaves
/// non-assistant content (especially tool commands) as literal text.
struct HaloMarkdownText: View {
    let text: String
    var interpretsMarkdown = true
    var workspaceRoot: String? = nil

    var body: some View {
        Text(HaloMarkdown.attributedString(
            from: text,
            interpretsMarkdown: interpretsMarkdown,
            workspaceRoot: workspaceRoot
        ))
            .tint(Color(red: 0.55, green: 0.74, blue: 1.0))
    }
}
