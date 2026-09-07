import SwiftUI

/// A selectable, native reader for the Markdown blocks produced by a meeting summary.
/// The caller owns scrolling and the surrounding document margins.
struct RecordingLibraryMarkdown: View {
    let markdown: String

    var body: some View {
        let blocks = Self.blocks(in: markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                blockView(item.element)
                    .padding(.top, Self.spacing(
                        before: item.element,
                        after: item.offset > 0 ? blocks[item.offset - 1] : nil
                    ))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.primary)
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.kind {
        case .heading(let level):
            prose(block.text)
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            prose(block.text)
        case .list(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker)
                    .font(.system(size: marker == "•" ? 12 : 14))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                prose(block.text)
                    .layoutPriority(1)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote:
            prose(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(width: 2)
                }
        case .divider:
            Divider()
        }
    }

    private func prose(_ text: String) -> some View {
        Text(Self.inline(text))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    /// Keep related lines together and use whitespace, rather than oversized type,
    /// to distinguish sections. The first block aligns with the surrounding reader.
    private static func spacing(before block: Block, after previous: Block?) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous.kind, block.kind) {
        case (_, .heading): return 24
        case (.heading, _): return 8
        case (.list, .list): return 7
        case (.divider, _), (_, .divider): return 18
        default: return 12
        }
    }

    private struct Block {
        enum Kind {
            case heading(Int)
            case paragraph
            case list(marker: String, depth: Int)
            case quote
            case divider
        }

        let kind: Kind
        var text: String
    }

    /// Intentionally handles a small block subset; inline Markdown is parsed by Foundation.
    /// Keeping the original text on a parse failure prevents silently dropping summary content.
    private static func blocks(in markdown: String) -> [Block] {
        var result: [Block] = []
        var pending: Block?

        func flush() {
            if let block = pending { result.append(block) }
            pending = nil
        }

        func appendLine(_ text: String) {
            if var block = pending {
                block.text += " " + text
                pending = block
            } else {
                pending = Block(kind: .paragraph, text: text)
            }
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flush()
                continue
            }

            let rule = line.filter { !$0.isWhitespace }
            if rule.count >= 3, let marker = rule.first,
               "-*_".contains(marker), rule.allSatisfy({ $0 == marker }) {
                flush()
                result.append(Block(kind: .divider, text: ""))
                continue
            }

            let hashes = line.prefix(while: { $0 == "#" }).count
            let headingText = line.dropFirst(hashes)
            if (1...6).contains(hashes),
               headingText.isEmpty || headingText.first?.isWhitespace == true {
                flush()
                let title = String(headingText)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                if !title.isEmpty { result.append(Block(kind: .heading(hashes), text: title)) }
                continue
            }

            if let range = line.range(of: "^(?:[-+*]|[0-9]{1,9}[.)])\\s+", options: .regularExpression) {
                flush()
                let prefix = String(line[range]).trimmingCharacters(in: .whitespaces)
                let marker = prefix.first?.isNumber == true ? prefix : "•"
                let indentation = rawLine.prefix(while: { $0.isWhitespace })
                    .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                pending = Block(kind: .list(marker: marker, depth: min(indentation / 2, 6)),
                                text: String(line[range.upperBound...]))
                continue
            }

            if line.hasPrefix(">") {
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let block = pending, case .quote = block.kind {
                    appendLine(text)
                } else {
                    flush()
                    pending = Block(kind: .quote, text: text)
                }
                continue
            }

            if let block = pending, case .quote = block.kind { flush() }
            appendLine(line)
        }
        flush()
        return result
    }
}
