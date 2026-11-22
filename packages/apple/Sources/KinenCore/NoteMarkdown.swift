import Foundation

public enum NoteMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String)
    case quote(String)
    case code(String)
    case divider
    case media(id: UUID, label: String)

    public static func parse(_ source: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = fence {
                let closing = trimmed.prefix { $0 == delimiter.first }
                if closing.count >= delimiter.count, trimmed.dropFirst(closing.count).isEmpty {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let delimiter = openingFence(trimmed) {
                endParagraph()
                fence = delimiter
            } else if trimmed.isEmpty {
                endParagraph()
            } else if let block = standaloneBlock(trimmed) {
                endParagraph()
                blocks.append(block)
            } else {
                paragraph.append(line)
            }
        }

        endParagraph()
        if fence != nil { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    public static func mediaIDs(in source: String) -> Set<UUID> {
        Set(parse(source).compactMap { block in
            if case .media(let id, _) = block { return id }
            return nil
        })
    }

    private static func openingFence(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let prefix = line.prefix { $0 == first }
        guard prefix.count >= 3, first != "`" || !line.dropFirst(prefix.count).contains("`") else { return nil }
        return String(prefix)
    }

    private static func standaloneBlock(_ line: String) -> Self? {
        if let media = mediaBlock(line) { return media }

        let heading = line.prefix { $0 == "#" }
        if (1...6).contains(heading.count), line.dropFirst(heading.count).first == " " {
            return .heading(level: heading.count,
                            text: line.dropFirst(heading.count).trimmingCharacters(in: .whitespaces))
        }
        let rule = line.filter { !$0.isWhitespace }
        if let marker = rule.first, rule.count >= 3, "-*_".contains(marker),
           rule.allSatisfy({ $0 == marker }) {
            return .divider
        }
        if line.hasPrefix(">"), let first = line.dropFirst().first, first.isWhitespace {
            return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            return .listItem(marker: "•", text: line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        let rest = line.dropFirst(digits.count)
        if (1...9).contains(digits.count), rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return .listItem(marker: "\(digits).", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func mediaBlock(_ line: String) -> Self? {
        let link = line.hasPrefix("![") ? line.dropFirst() : line[...]
        guard link.hasPrefix("["), link.hasSuffix(")"),
              let separator = link.range(of: "](media:", options: .backwards),
              let id = UUID(uuidString: String(link[separator.upperBound..<link.index(before: link.endIndex)])) else {
            return nil
        }
        return .media(id: id, label: String(link[link.index(after: link.startIndex)..<separator.lowerBound]))
    }
}
