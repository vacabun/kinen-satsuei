import Foundation

public struct NoteCard: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, heading, quote, bullets, numbered, media, divider, markdown, itinerary, relatedNote
    }

    public struct Media: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let label: String
        public let video: Bool

        public init(id: UUID, label: String, video: Bool) {
            self.id = id
            self.label = label
            self.video = video
        }

        fileprivate var markdown: String {
            let safeLabel = label.replacingOccurrences(of: "]", with: "）")
            return "\(video ? "" : "!")[\(safeLabel)](media:\(id.uuidString.lowercased()))"
        }
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var locked: Bool
    public var media: [Media]
    public var stop: TravelStop?
    public var noteID: UUID?

    public init(id: UUID = UUID(), kind: Kind, text: String = "", locked: Bool = false,
                media: [Media] = [], stop: TravelStop? = nil, noteID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.locked = locked
        self.media = media
        self.stop = stop
        self.noteID = noteID
    }

    public static func markdown(_ cards: [Self]) -> String {
        cards.map(\.markdown).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var markdown: String {
        switch kind {
        case .text, .markdown: text
        case .heading: text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { "## " + $0 }.joined(separator: "\n")
        case .quote: text.isEmpty ? "" : text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        case .bullets, .numbered: text.split(separator: "\n").enumerated().map { index, line in
            (kind == .bullets ? "- " : "\(index + 1). ") + line
        }.joined(separator: "\n")
        case .media: media.map(\.markdown).joined(separator: "\n")
        case .divider: "---"
        case .itinerary:
            stop.map { stop in
                let context = [stop.date, stop.time, stop.location.isEmpty ? nil : stop.location]
                    .compactMap { $0 }.joined(separator: " · ")
                return ["### " + stop.title, context, stop.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
            } ?? ""
        case .relatedNote:
            noteID.map { "[\(text.replacingOccurrences(of: "]", with: "）"))](note:\($0.uuidString.lowercased()))" } ?? ""
        }
    }

    /// Converts ordinary Markdown blocks without reconstructing unsupported syntax.
    public static func fromMarkdown(_ source: String) -> [Self] {
        guard !source.isEmpty else { return [] }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var groups: [String] = []
        var lines: [String] = []
        var fence: (Character, Int)?
        for line in normalized.components(separatedBy: "\n") {
            let content = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let marker = content.prefix { $0 == current.0 }
                if marker.count >= current.1 && marker.count == content.count { fence = nil }
            } else if let first = content.first, first == "`" || first == "~" {
                let marker = content.prefix { $0 == first }
                if marker.count >= 3 { fence = (first, marker.count) }
            } else if content.isEmpty {
                if !lines.isEmpty { groups.append(lines.joined(separator: "\n")); lines = [] }
                continue
            }
            lines.append(line)
        }
        if !lines.isEmpty { groups.append(lines.joined(separator: "\n")) }
        return groups.map { group in
            let parsed = NoteMarkdownBlock.parse(group)
            let cards = parsed.compactMap { block -> Self? in
                switch block {
                case .heading(level: 2, let text): Self(kind: .heading, text: text)
                case .paragraph(let text): Self(kind: .text, text: text)
                case .quote(let text): Self(kind: .quote, text: text)
                case .divider: Self(kind: .divider)
                case .media(let id, let label):
                    Self(kind: .media, media: [Media(id: id, label: label, video: !group.hasPrefix("!"))])
                default: nil
                }
            }
            if !cards.isEmpty && cards.allSatisfy({ $0.kind == .media }) &&
                cards.count == parsed.count && cards.map(\.markdown).joined(separator: "\n") == group {
                return Self(kind: .media, media: cards.flatMap(\.media))
            }
            var listItems: [String] = []
            var listStyle: Kind?
            for block in parsed {
                guard case .listItem(let marker, let text) = block else { break }
                let style: Kind = marker == "•" ? .bullets : .numbered
                if let listStyle, listStyle != style { break }
                listStyle = style
                listItems.append(text)
            }
            if let listStyle, listItems.count == parsed.count {
                let list = Self(kind: listStyle, text: listItems.joined(separator: "\n"))
                if list.markdown == group { return list }
            }
            if cards.count == 1, parsed.count == 1, let card = cards.first, card.markdown == group {
                return card
            }
            return Self(kind: .markdown, text: group)
        }
    }
}

public extension LibraryEntry {
    var cardContentMatchesMarkdown: Bool {
        guard let noteCards else { return true }
        return Set(noteCards.map(\.id)).count == noteCards.count &&
            NoteCard.markdown(noteCards) == body && noteCards.compactMap(\.stop) == itinerary
    }

    mutating func replaceNoteCards(_ cards: [NoteCard]) {
        noteCards = cards
        body = NoteCard.markdown(cards)
        itinerary = cards.compactMap(\.stop)
    }
}

extension NoteCard {
    /// Merge identity and content separately so moving a card doesn't discard the other device's edits.
    static func merge(base: [Self], local: [Self], remote: [Self], preferring choice: SyncConflictChoice?) -> [Self]? {
        let original = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let ours = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let theirs = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var values: [UUID: Self] = [:]

        for id in Set(original.keys).union(ours.keys).union(theirs.keys) {
            let before = original[id]
            let left = ours[id]
            let right = theirs[id]
            if left == right || right == before {
                values[id] = left
            } else if left == before {
                values[id] = right
            } else if let before, let left, let right, left.kind == before.kind, right.kind == before.kind {
                var merged = before
                var conflicted = false
                func field<Value: Equatable>(_ key: WritableKeyPath<Self, Value>) {
                    let a = before[keyPath: key]
                    let b = left[keyPath: key]
                    let c = right[keyPath: key]
                    if b == c || c == a { merged[keyPath: key] = b }
                    else if b == a { merged[keyPath: key] = c }
                    else if let choice { merged[keyPath: key] = choice == .local ? b : c }
                    else { conflicted = true }
                }
                field(\.locked)
                field(\.media)
                field(\.stop)
                field(\.noteID)
                if let text = MarkdownMerge.merge(base: before.text, local: left.text, remote: right.text) {
                    merged.text = text
                } else {
                    field(\.text)
                }
                guard !conflicted else { return nil }
                values[id] = merged
            } else if let choice {
                values[id] = choice == .local ? left : right
            } else {
                return nil
            }
        }

        // Compare relative order among the surviving original cards. Additions use
        // their nearest predecessor in each branch, independently of its position.
        let surviving = Set(values.keys).intersection(original.keys)
        let baseOrder = base.map(\.id).filter { surviving.contains($0) }
        func originalOrder(_ branch: [Self]) -> [UUID] {
            let ids = branch.map(\.id).filter { surviving.contains($0) }
            // A card explicitly kept after a deletion conflict is missing from one side.
            return ids.count == baseOrder.count ? ids : baseOrder
        }
        let localOrder = originalOrder(local)
        let remoteOrder = originalOrder(remote)
        var order: [UUID]
        if localOrder == remoteOrder || remoteOrder == baseOrder { order = localOrder }
        else if localOrder == baseOrder { order = remoteOrder }
        else if let choice { order = choice == .local ? localOrder : remoteOrder }
        else { return nil }

        func additions(_ branch: [Self]) -> [UUID?: [UUID]] {
            var result: [UUID?: [UUID]] = [:]
            var anchor: UUID?
            for card in branch where values[card.id] != nil {
                if surviving.contains(card.id) { anchor = card.id }
                else { result[anchor, default: []].append(card.id) }
            }
            return result
        }
        let leftAdds = additions(local)
        let rightAdds = additions(remote)
        var mergedOrder: [UUID] = []
        var seen = Set<UUID>()
        for anchor in [nil] + order.map(Optional.some) {
            if let anchor { mergedOrder.append(anchor) }
            let a = leftAdds[anchor] ?? []
            let b = rightAdds[anchor] ?? []
            if !a.isEmpty && !b.isEmpty && a != b && choice == nil { return nil }
            let additions = choice == .remote ? b + a : a + b
            mergedOrder.append(contentsOf: additions.filter { seen.insert($0).inserted })
        }
        return mergedOrder.compactMap { values[$0] }
    }

}

public extension NoteCard {
    static func suggestedTitle(from cards: [Self], fallback: String) -> String {
        for card in cards {
            switch card.kind {
            case .text, .heading, .quote, .bullets, .numbered, .markdown:
                let excerpt = String(card.text.prefix(400))
                let plain = NoteMarkdownBlock.parse(excerpt).compactMap { block -> String? in
                    switch block {
                    case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, let text):
                        text
                    default:
                        nil
                    }
                }
                for text in plain {
                    for line in text.split(whereSeparator: \.isNewline) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return String(trimmed.prefix(28)) }
                    }
                }
            default:
                continue
            }
        }
        return fallback
    }
}
