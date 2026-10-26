import CryptoKit
import Foundation

/// Rendering-only protection for math before Markdown consumes `_`, `*`, brackets and escapes.
/// Source messages are never rewritten: replacements are restored after ordinary Markdown parsing.
public enum HermesMathMarkdown {
    public struct Replacement: Sendable, Equatable {
        public enum Kind: Sendable { case inlineMath, displayMath, literal }
        public let marker: String
        public let source: String
        public let content: String
        public let kind: Kind

        /// The pinned Textual parser recognizes math *after* Foundation's Markdown parser. Escape
        /// the isolated expression so that parser sees exactly one intact LaTeX run.
        public var isolatedMarkdown: String {
            guard kind != .literal else { return "" }
            let latex = content.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let punctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
            var protected = ""
            for scalar in latex.unicodeScalars {
                if punctuation.contains(scalar) { protected.append("\\") }
                protected.unicodeScalars.append(scalar)
            }
            let delimiter = kind == .displayMath ? "$$" : "$"
            return delimiter + protected + delimiter
        }
    }
    public struct Document: Sendable, Equatable {
        public let markdown: String
        public let replacements: [Replacement]
    }

    public static func prepare(_ source: String) -> Document {
        var lexer = Lexer(source)
        return lexer.run()
    }

    private struct Lexer {
        let bytes: [UInt8]
        let prefix: String
        let lineEnds: [Int]
        var cursor = 0
        var rawStart = 0
        var output = ""
        var replacements: [Replacement] = []
        let environments: Set<String> = ["equation", "equation*", "align", "align*", "aligned", "split", "eqalign",
            "gather", "gather*", "gathered", "multline", "multline*", "eqnarray", "eqnarray*",
            "matrix", "matrix*", "pmatrix", "pmatrix*", "bmatrix", "bmatrix*", "Bmatrix", "Bmatrix*",
            "vmatrix", "vmatrix*", "Vmatrix", "Vmatrix*", "smallmatrix", "cases"]
        init(_ source: String) {
            bytes = Array(source.utf8)
            lineEnds = bytes.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil } + [bytes.count]
            let digest = SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            var candidate = "\u{E000}HM" + digest
            while source.contains(candidate) { candidate += "X" }
            prefix = candidate
        }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func matches(_ token: [UInt8], at index: Int) -> Bool {
            index >= 0 && index + token.count <= bytes.count && bytes[index..<(index + token.count)].elementsEqual(token)
        }
        func escaped(_ index: Int) -> Bool {
            var start = index
            while start > 0 && bytes[start - 1] == 92 { start -= 1 }
            return (index - start) % 2 == 1
        }
        func lineEnd(_ index: Int) -> Int {
            var lower = 0, upper = lineEnds.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if lineEnds[middle] <= index { lower = middle + 1 } else { upper = middle }
            }
            return lower < lineEnds.count ? lineEnds[lower] : bytes.count
        }
        func afterBlockquotePrefix(_ initial: Int) -> Int {
            var index = initial
            while index < bytes.count && bytes[index] == 62 {
                index += 1
                if index < bytes.count && bytes[index] == 32 { index += 1 }
                var spaces = 0
                while index < bytes.count && bytes[index] == 32 && spaces < 3 { index += 1; spaces += 1 }
            }
            return index
        }
        func runEnd(_ index: Int, byte: UInt8) -> Int {
            var end = index
            while end < bytes.count && bytes[end] == byte { end += 1 }
            return end
        }
        mutating func protect(until end: Int, content: String, kind: Replacement.Kind) {
            output += text(rawStart..<cursor)
            let marker = prefix + String(replacements.count) + "\u{E001}"
            replacements.append(.init(marker: marker, source: text(cursor..<end), content: content, kind: kind))
            output += marker
            cursor = end; rawStart = end
        }
        mutating func skipFence() -> Bool {
            guard cursor == 0 || bytes[cursor - 1] == 10 else { return false }
            var start = cursor
            while start < bytes.count && bytes[start] == 32 && start - cursor < 4 { start += 1 }
            if start - cursor >= 4 || (start < bytes.count && bytes[start] == 9) {
                // Indented Markdown code is never scanned for math.
                cursor = lineEnd(cursor); return true
            }
            start = afterBlockquotePrefix(start)
            if start + 1 < bytes.count, [45, 43, 42].contains(bytes[start]), bytes[start + 1] == 32 {
                start += 2
                while start < bytes.count && bytes[start] == 32 { start += 1 }
            }
            guard start < bytes.count, bytes[start] == 96 || bytes[start] == 126 else { return false }
            let fenceByte = bytes[start]
            let fenceEnd = runEnd(start, byte: fenceByte)
            guard fenceEnd - start >= 3 else { return false }
            let length = fenceEnd - start
            let firstEnd = lineEnd(fenceEnd)
            let language = text(fenceEnd..<firstEnd).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var line = firstEnd
            while line < bytes.count {
                var position = line
                while position < bytes.count && bytes[position] == 32 && position - line < 4 { position += 1 }
                let indentation = position - line
                position = afterBlockquotePrefix(position)
                if indentation < 4, position < bytes.count, bytes[position] == fenceByte {
                    let end = runEnd(position, byte: fenceByte)
                    let restEnd = lineEnd(end)
                    if end - position >= length && text(end..<restEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if language == "math" {
                            // Textual renders explicit math fences natively without the inline math
                            // extension. Keep the fence, but adapt document-level environments inside.
                            output += text(rawStart..<cursor) + text(cursor..<firstEnd)
                            let body = text(firstEnd..<line)
                            let newline = body.contains("\r\n") ? "\r\n" : "\n"
                            output += normalizedEnvironment(body) + newline + text(line..<restEnd)
                            rawStart = restEnd
                        }
                        cursor = restEnd; return true
                    }
                }
                line = lineEnd(line)
            }
            // Do not feed a still-streaming ```math block to the native LaTeX renderer.
            if language == "math" { protect(until: bytes.count, content: text(cursor..<bytes.count), kind: .literal) }
            else { cursor = bytes.count }
            return true
        }
        mutating func skipInlineCode() -> Bool {
            guard bytes[cursor] == 96 && !escaped(cursor) else { return false }
            let openingEnd = runEnd(cursor, byte: 96)
            let length = openingEnd - cursor
            var next = openingEnd
            while next < bytes.count {
                if bytes[next] == 96 {
                    let end = runEnd(next, byte: 96)
                    if end - next == length { cursor = end; return true }
                    next = end
                } else { next += 1 }
            }
            // An unfinished code span remains literal while the stream is arriving.
            protect(until: bytes.count, content: text(cursor..<bytes.count), kind: .literal)
            return true
        }
        func closing(_ delimiter: [UInt8], from start: Int, singleLine: Bool) -> Int? {
            var index = start
            while index < bytes.count {
                if singleLine && (bytes[index] == 10 || bytes[index] == 13) { return nil }
                if matches(delimiter, at: index), !escaped(index) {
                    if delimiter == [36] {
                        // Whitespace before a closing dollar or a following digit is a price, not math.
                        let followingDigit = index + 1 < bytes.count && (48...57).contains(bytes[index + 1])
                        if index == start || bytes[index - 1] == 32 || bytes[index - 1] == 9 || followingDigit {
                            return nil
                        }
                        if index + 1 < bytes.count && bytes[index + 1] == 36 { return nil }
                    }
                    return index
                }
                index += 1
            }
            return nil
        }
        func probableUnfinishedMath(_ body: String) -> Bool {
            body.contains("\\") || body.contains("_") || body.contains("^") || body.contains("{") || body.contains("=")
        }
        func environment(at index: Int, command: String) -> (name: String, end: Int)? {
            let prefix = Array(("\\" + command + "{").utf8)
            guard matches(prefix, at: index), !escaped(index) else { return nil }
            var end = index + prefix.count
            while end < bytes.count && bytes[end] != 125 && end - index < 48 { end += 1 }
            guard end < bytes.count && bytes[end] == 125 else { return nil }
            return (text((index + prefix.count)..<end), end + 1)
        }
        mutating func mathEnvironment() -> Bool {
            guard let initial = environment(at: cursor, command: "begin"), environments.contains(initial.name) else { return false }
            var stack = [initial.name]
            var index = initial.end
            while index < bytes.count {
                if let opening = environment(at: index, command: "begin") {
                    stack.append(opening.name); index = opening.end; continue
                }
                if let end = environment(at: index, command: "end") {
                    guard stack.last == end.name else { index = end.end; continue }
                    stack.removeLast()
                    if stack.isEmpty {
                        let source = text(cursor..<end.end)
                        protect(until: end.end, content: normalizedEnvironment(source), kind: .displayMath)
                        return true
                    }
                    index = end.end; continue
                }
                index += 1
            }
            protect(until: bytes.count, content: text(cursor..<bytes.count), kind: .literal)
            return true
        }
        func normalizedEnvironment(_ source: String) -> String {
            var result = source
            // SwiftUIMath 0.1 supports aligned/gather/matrices/cases. Normalize common document-level
            // wrappers to those math-mode environments, without changing original copy/save data.
            for name in ["equation", "equation*"] {
                result = result.replacingOccurrences(of: "\\begin{\(name)}", with: "")
                    .replacingOccurrences(of: "\\end{\(name)}", with: "")
            }
            for (name, target) in [("align", "aligned"), ("align*", "aligned"), ("gather*", "gather"),
                                   ("gathered", "gather"), ("multline", "gather"), ("multline*", "gather"), ("eqnarray*", "eqnarray")] {
                result = result.replacingOccurrences(of: "\\begin{\(name)}", with: "\\begin{\(target)}")
                    .replacingOccurrences(of: "\\end{\(name)}", with: "\\end{\(target)}")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        mutating func run() -> Document {
            while cursor < bytes.count {
                if skipFence() || skipInlineCode() { continue }
                if bytes[cursor] == 92 && !escaped(cursor) {
                    if mathEnvironment() { continue }
                    let inline = matches([92, 40], at: cursor)
                    let display = matches([92, 91], at: cursor)
                    if inline || display {
                        let delimiter: [UInt8] = inline ? [92, 41] : [92, 93]
                        if let end = closing(delimiter, from: cursor + 2, singleLine: false) {
                            protect(until: end + 2, content: normalizedEnvironment(text((cursor + 2)..<end)), kind: inline ? .inlineMath : .displayMath)
                        } else { protect(until: bytes.count, content: text(cursor..<bytes.count), kind: .literal) }
                        continue
                    }
                }
                if bytes[cursor] == 36 && !escaped(cursor) {
                    let display = matches([36, 36], at: cursor)
                    let count = display ? 2 : 1
                    let begin = cursor + count
                    if begin < bytes.count && (display || (bytes[begin] != 32 && bytes[begin] != 9 && bytes[begin] != 10)) {
                        let delimiter: [UInt8] = display ? [36, 36] : [36]
                        if let end = closing(delimiter, from: begin, singleLine: !display), end > begin {
                            protect(until: end + count, content: normalizedEnvironment(text(begin..<end)), kind: display ? .displayMath : .inlineMath)
                            continue
                        } else if display {
                            protect(until: bytes.count, content: text(cursor..<bytes.count), kind: .literal)
                            continue
                        } else {
                            let endOfLine = lineEnd(begin)
                            let end = endOfLine > begin && bytes[endOfLine - 1] == 10 ? endOfLine - 1 : endOfLine
                            if !bytes[begin..<end].contains(36), probableUnfinishedMath(text(begin..<end)) {
                                protect(until: end, content: text(cursor..<end), kind: .literal)
                                continue
                            }
                        }
                    }
                }
                cursor += 1
            }
            output += text(rawStart..<bytes.count)
            return Document(markdown: output, replacements: replacements)
        }
    }
}
