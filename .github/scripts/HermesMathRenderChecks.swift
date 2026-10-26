import Foundation
import IslandCore
import Textual

private struct MathRenderFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private func assertRender(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw MathRenderFailure(description: message) }
}

@MainActor private func attachments(_ attributed: AttributedString) -> [String] {
    attributed.runs.compactMap { $0.attachment?.description }
}

/// Runs the actual pinned Textual parser. It creates no windows, reads no clipboard and contacts no
/// Hermes service; native attachments are inspected before presentation by StructuredText.
@main private struct HermesMathRenderChecks {
    @MainActor static func main() throws {
        let parser = HermesMarkdownParser()
        let objective = #"期望回报目标函数： $$\mathcal{J}(\theta) = \mathbb{E}_{\tau \sim \pi_\theta} [R(\tau)]$$"#
        let gradient = #"策略梯度： $$\nabla_\theta J(\theta) = \mathbb{E}_{\tau\sim\pi_\theta}\left[\sum_{t=0}^{T}\nabla_\theta\log\pi_\theta(a_t|s_t)R(\tau)\right]$$"#
        for source in [objective, gradient] {
            let result = try parser.attributedString(for: source)
            let native = attachments(result)
            let expected = HermesMathMarkdown.prepare(source).replacements[0]
            try assertRender(native == ["$$" + expected.content + "$$"], "Screenshot formula lost or changed native LaTeX attachment")
            try assertRender(String(result.characters).contains("\u{FFFC}") && !String(result.characters).contains("$$"),
                             "Screenshot formula remained literal instead of native attachment")
        }
        let original = try AttributedStringMarkdownParser(baseURL: nil, syntaxExtensions: [.math]).attributedString(for: objective)
        print("Baseline native attachment count: \(attachments(original).count); protected parser: 1 per screenshot formula")

        let inline = try parser.attributedString(for: #"**目标**：\(x_i = \frac{a_b}{c_d}\) 和 $y_j^2$。"#)
        try assertRender(attachments(inline) == [#"$x_i = \frac{a_b}{c_d}$"#, "$y_j^2$"], "Inline math delimiters or subscripts corrupted")
        try assertRender(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
                         "Normal Markdown bold formatting was lost")
        let display = try parser.attributedString(for: "显示：\\[\n\\begin{aligned}\na_i &= b_i \\\\\nc_i &= d_i\n\\end{aligned}\n\\]")
        try assertRender(attachments(display).count == 1 && attachments(display)[0].contains(#"a_i &= b_i \\"#),
                         "Multiline display math lost row separator")
        let environment = try parser.attributedString(for: #"\begin{align*}a&=b\\c&=d\end{align*}"#)
        try assertRender(attachments(environment) == [#"$$\begin{aligned}a&=b\\c&=d\end{aligned}$$"#],
                         "Common align environment was not normalized to native supported form")

        let codeInput = "```swift\nlet x = \"$$not_math$$\"\n```\n\n`$x_i$` and ``\\[x_i\\]``"
        let code = try parser.attributedString(for: codeInput)
        try assertRender(attachments(code).isEmpty && String(code.characters).contains("$$not_math$$")
            && String(code.characters).contains("$x_i$"), "Code content became math")
        try assertRender(code.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true },
                         "Inline code styling was lost")
        let currencyInput = #"价格 $5 和 $10；成本 \$20。税费 $30.00。"#
        let currencies = try parser.attributedString(for: currencyInput)
        try assertRender(attachments(currencies).isEmpty && String(currencies.characters).contains("$20"), "Currency became math")
        let mixed = try parser.attributedString(for: #"价格 $5 和 $10，公式 $x_i$。"#)
        try assertRender(attachments(mixed) == ["$x_i$"], "Currency swallowed adjacent real formula")

        for index in objective.indices {
            let prefix = String(objective[..<index])
            let result = try parser.attributedString(for: prefix)
            let protected = HermesMathMarkdown.prepare(prefix)
            if protected.replacements.contains(where: { $0.kind == .literal }) {
                try assertRender(attachments(result).isEmpty, "An incomplete SSE formula reached the native math renderer")
                try assertRender(protected.replacements.allSatisfy { String(result.characters).contains($0.content) },
                                 "Partial SSE formula lost raw underscores or commands")
            }
        }
        let partialCode = try parser.attributedString(for: "```math\n\\frac{a_b}{")
        try assertRender(attachments(partialCode).isEmpty && String(partialCode.characters).contains("\\frac{a_b}{"),
                         "Incomplete math fence was not retained as literal")
        print("PASS actual native Textual math: screenshot formulas, inline/display/environment attachments, Markdown/code/currency and SSE prefixes")
    }
}
