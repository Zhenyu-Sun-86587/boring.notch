import Foundation
import IslandCore

private struct HermesMathCheckFailure: Error { let description: String }
private func mathAssert(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw HermesMathCheckFailure(description: description) }
}

func runHermesMathMarkdownChecks() throws {
    let objective = #"期望回报目标函数： $$\mathcal{J}(\theta) = \mathbb{E}_{\tau \sim \pi_\theta} [R(\tau)]$$"#
    let gradient = #"策略梯度： $$\nabla_\theta J(\theta) = \mathbb{E}_{\tau\sim\pi_\theta}\left[\sum_{t=0}^{T}\nabla_\theta\log\pi_\theta(a_t|s_t)R(\tau)\right]$$"#
    for input in [objective, gradient] {
        let prepared = HermesMathMarkdown.prepare(input)
        try mathAssert(prepared.replacements.count == 1 && prepared.replacements[0].kind == .displayMath, "same-line display math recognized before Markdown")
        let expression = prepared.replacements[0]
        let foundation = try AttributedString(markdown: expression.isolatedMarkdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        try mathAssert(String(foundation.characters) == "$$" + expression.content + "$$", "Foundation retains all LaTeX underscores, brackets and backslashes")
        try mathAssert(foundation.runs.count == 1, "isolated formula stays one attributed run for native Textual math")
        try mathAssert(prepared.markdown.contains("： ") && !prepared.markdown.contains("\\theta"), "surrounding prose stays Markdown, formula protected")
    }
    let inline = HermesMathMarkdown.prepare(#"内联 \(x_i = \frac{a_b}{c_d}\) 和 $y_j^2$。"#)
    try mathAssert(inline.replacements.count == 2 && inline.replacements.allSatisfy { $0.kind == .inlineMath }, "parenthesis and dollar inline syntax")
    let multiline = HermesMathMarkdown.prepare("显示：\\[\n\\begin{aligned}\na_i &= b_i \\\\\nc_i &= d_i\n\\end{aligned}\n\\]")
    try mathAssert(multiline.replacements.count == 1 && multiline.replacements[0].kind == .displayMath, "bracket multiline display")
    let flattened = try AttributedString(markdown: multiline.replacements[0].isolatedMarkdown,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    try mathAssert(String(flattened.characters).contains(#"a_i &= b_i \\"#), "math row separators survive Markdown")

    let environment = HermesMathMarkdown.prepare(#"目标 \begin{equation*}J_\theta=\mathbb{E}[R]\end{equation*} 结束"#)
    try mathAssert(environment.replacements.count == 1 && environment.replacements[0].content == #"J_\theta=\mathbb{E}[R]"#, "equation wrapper normalized for math-mode renderer")
    let align = HermesMathMarkdown.prepare(#"\begin{align*}a&=b\\c&=d\end{align*}"#)
    try mathAssert(align.replacements[0].content == #"\begin{aligned}a&=b\\c&=d\end{aligned}"#, "align maps to supported aligned environment")
    let cases = HermesMathMarkdown.prepare(#"\begin{equation}\begin{cases}x&x>0\\0&x\le0\end{cases}\end{equation}"#)
    try mathAssert(cases.replacements.count == 1 && cases.replacements[0].content.contains(#"\begin{cases}"#), "nested environments stay intact")

    let fenced = "```swift\nlet value = \"$$x_i$$\"\n```\n\n~~~text\n\\(x_i\\)\n~~~\n`$x_i$` and ``\\[x_i\\]``"
    let code = HermesMathMarkdown.prepare(fenced)
    try mathAssert(code.markdown == fenced && code.replacements.isEmpty, "fenced and inline code untouched")
    let quotedFence = "> ~~~text\n> $$not_math$$\n> ~~~\n\n- ```txt\n  $not_math$\n  ```"
    let quoted = HermesMathMarkdown.prepare(quotedFence)
    try mathAssert(quoted.replacements.isEmpty && quoted.markdown == quotedFence, "blockquote/list code fences untouched")
    let explicitMathFence = "```math\n\\begin{align*}a&=b\\\\c&=d\\end{align*}\n```\n"
    let mathFence = HermesMathMarkdown.prepare(explicitMathFence)
    try mathAssert(mathFence.markdown.contains("```math\n") && mathFence.markdown.contains(#"\begin{aligned}"#)
        && mathFence.markdown.hasSuffix("\n```\n"), "explicit math fence keeps Markdown boundaries while adapting supported environments")
    let indented = "    $$not_math$$\n\t\\(not_math\\)\n"
    try mathAssert(HermesMathMarkdown.prepare(indented).replacements.isEmpty, "indented code untouched")
    let money = #"价格 $5 和 $10；成本 \$20。税费 $30.00，预算 $40。"#
    try mathAssert(HermesMathMarkdown.prepare(money).replacements.isEmpty, "currency and escaped dollars are not math")
    let moneyAndMath = HermesMathMarkdown.prepare(#"价格 $5 和 $10，公式 $x_i$。"#)
    try mathAssert(moneyAndMath.replacements.count == 1 && moneyAndMath.replacements[0].content == "x_i", "prices do not swallow later math")
    let mathDollar = HermesMathMarkdown.prepare(#"$\text{cost}=\$5$"#)
    try mathAssert(mathDollar.replacements.count == 1, "escaped dollar inside math")

    for input in [#"前缀 $$\mathcal{J}_\theta"#, #"前缀 \[\frac{a_b}{c"#, #"前缀 \(x_i"#, #"前缀 $x_i"#, "```math\n\\frac{a_b}{"] {
        let partial = HermesMathMarkdown.prepare(input)
        try mathAssert(partial.replacements.count == 1 && partial.replacements[0].kind == .literal, "incomplete streaming math is literal until closed")
        try mathAssert(partial.replacements[0].source == partial.replacements[0].content, "partial content has no guessed delimiters")
    }
    // Every possible SSE prefix must be safe, and closing the expression must yield the same parse.
    for index in objective.indices {
        let prefix = String(objective[..<index])
        let first = HermesMathMarkdown.prepare(prefix)
        try mathAssert(first == HermesMathMarkdown.prepare(prefix), "stream-prefix parse is deterministic")
    }
    try mathAssert(HermesMathMarkdown.prepare(objective) == HermesMathMarkdown.prepare(objective), "complete parse deterministic")
    let mixed = #"**目标**：$x_1$，`$code$`，\$20。$$\begin{matrix}a&b\\c&d\end{matrix}$$"#
    let result = HermesMathMarkdown.prepare(mixed)
    try mathAssert(result.replacements.count == 2 && result.markdown.contains("**目标**") && result.markdown.contains("`$code$`"), "mixed Markdown retained")
    let prices = String(repeating: "$5 and $10, ", count: 8_000)
    let pricesPrepared = HermesMathMarkdown.prepare(prices)
    try mathAssert(pricesPrepared.replacements.isEmpty && pricesPrepared.markdown == prices, "large price lists stay literal without quadratic tail copying")
    print("PASS Hermes render-only math protection: screenshot formulas, inline/display syntax, environments, code, currency and streaming prefixes")
}
