import Foundation
import IslandCore
import Textual

/// Textual's built-in math extension runs after Markdown and once per attributed run. Protect
/// formulas first, then use that native extension only on intact isolated LaTeX expressions.
@MainActor
struct HermesMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        let document = HermesMathMarkdown.prepare(input)
        var result = try AttributedStringMarkdownParser(baseURL: nil).attributedString(for: document.markdown)
        let math = AttributedStringMarkdownParser(baseURL: nil,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), syntaxExtensions: [.math])
        for replacement in document.replacements.reversed() {
            guard let range = result.range(of: replacement.marker) else { continue }
            let attributes = result[range].runs.first?.attributes ?? AttributeContainer()
            var restored: AttributedString
            if replacement.kind == .literal {
                restored = AttributedString(replacement.content)
            } else {
                restored = try math.attributedString(for: replacement.isolatedMarkdown)
                // Unsupported/incomplete syntax must remain readable instead of disappearing.
                if String(restored.characters) != "\u{FFFC}" { restored = AttributedString(replacement.source) }
            }
            restored.mergeAttributes(attributes)
            result.replaceSubrange(range, with: restored)
        }
        return result
    }
}
