import Foundation

public enum EntryConflictField: String, Sendable {
    case identity, deletion, addition, kind, title, startDate, endDate, parent, media, itinerary, body, cover, location, cards
}

public struct EntryMergeConflict: Sendable {
    public let fields: [EntryConflictField]
    public let base: LibraryEntry?
    public let local: LibraryEntry?
    public let remote: LibraryEntry?
    public var structural = false
}

public enum EntryMergeResult: Sendable {
    case merged(LibraryEntry?)
    case conflict(EntryMergeConflict)
}

public struct EntryMergePlan: Sendable {
    public let entries: [LibraryEntry]
    public let conflicts: [UUID: EntryMergeConflict]
}

public enum EntryMerge {
    public static func plan(base: [LibraryEntry], local: [LibraryEntry], remote: [LibraryEntry],
                            resolve: (UUID, EntryMergeConflict) -> SyncConflictChoice? = { _, _ in nil }) -> EntryMergePlan {
        func indexed(_ entries: [LibraryEntry]) -> [UUID: LibraryEntry] {
            Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let baseByID = indexed(base)
        let localByID = indexed(local)
        let remoteByID = indexed(remote)
        let ids = Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys)
        var merged: [UUID: LibraryEntry] = [:]
        var conflicts: [UUID: EntryMergeConflict] = [:]

        for id in ids {
            let result = merge(base: baseByID[id], local: localByID[id], remote: remoteByID[id])
            let resolved: EntryMergeResult
            if case .conflict(let conflict) = result, let choice = resolve(id, conflict) {
                resolved = merge(base: conflict.base, local: conflict.local, remote: conflict.remote, preferring: choice)
            } else {
                resolved = result
            }
            switch resolved {
            case .merged(let entry): merged[id] = entry
            case .conflict(let conflict): conflicts[id] = conflict
            }
        }
        let unresolvedParents = Set(conflicts.keys)
        for entry in merged.values {
            guard let parentID = entry.parentId, !unresolvedParents.contains(parentID) else { continue }
            let validParent = merged[parentID].map { $0.id != entry.id && $0.kind.allowsChild(entry.kind) } ?? false
            if !validParent {
                conflicts[entry.id] = EntryMergeConflict(fields: [.parent], base: baseByID[entry.id],
                                                         local: localByID[entry.id], remote: remoteByID[entry.id],
                                                         structural: true)
            }
        }
        let candidates = merged.values.filter { conflicts[$0.id] == nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        return EntryMergePlan(entries: candidates, conflicts: conflicts)
    }

    public static func merge(base: LibraryEntry?, local: LibraryEntry?, remote: LibraryEntry?,
                             preferring choice: SyncConflictChoice? = nil) -> EntryMergeResult {
        func conflict(_ fields: [EntryConflictField]) -> EntryMergeResult {
            .conflict(EntryMergeConflict(fields: fields, base: base, local: local, remote: remote))
        }

        let ids = Set([base, local, remote].compactMap { $0?.id })
        guard ids.count <= 1 else { return conflict([.identity]) }
        if local == remote { return .merged(local) }
        if local == base { return .merged(remote) }
        if remote == base { return .merged(local) }
        guard let base else {
            if let choice { return .merged(choice == .local ? local : remote) }
            return conflict([.addition])
        }
        guard let local, let remote else {
            if let choice { return .merged(choice == .local ? local : remote) }
            return conflict([.deletion])
        }

        var merged = base
        var conflicts: [EntryConflictField] = []
        func combine<Value: Equatable>(_ path: WritableKeyPath<LibraryEntry, Value>, field: EntryConflictField) {
            let original = base[keyPath: path]
            let ours = local[keyPath: path]
            let theirs = remote[keyPath: path]
            if ours == theirs || theirs == original {
                merged[keyPath: path] = ours
            } else if ours == original {
                merged[keyPath: path] = theirs
            } else if let choice {
                merged[keyPath: path] = choice == .local ? ours : theirs
            } else {
                conflicts.append(field)
            }
        }

        combine(\.kind, field: .kind)
        combine(\.title, field: .title)
        combine(\.startDate, field: .startDate)
        combine(\.endDate, field: .endDate)
        combine(\.parentId, field: .parent)
        combine(\.coverMediaId, field: .cover)
        combine(\.location, field: .location)
        if let baseCards = base.noteCards, let localCards = local.noteCards, let remoteCards = remote.noteCards,
           base.cardContentMatchesMarkdown, local.cardContentMatchesMarkdown, remote.cardContentMatchesMarkdown {
            if let cards = NoteCard.merge(base: baseCards, local: localCards, remote: remoteCards, preferring: choice) {
                func manualMedia(_ entry: LibraryEntry) -> [UUID] {
                    let inline = NoteMarkdownBlock.mediaIDs(in: entry.body)
                    return entry.mediaIds.filter { !inline.contains($0) }
                }
                let original = manualMedia(base)
                let ours = manualMedia(local)
                let theirs = manualMedia(remote)
                var attachments: [UUID] = []
                if ours == theirs || theirs == original { attachments = ours }
                else if ours == original { attachments = theirs }
                else if let choice { attachments = choice == .local ? ours : theirs }
                else { conflicts.append(.media) }
                merged.replaceNoteCards(cards)
                let inline = NoteMarkdownBlock.mediaIDs(in: merged.body)
                let known = Set(base.mediaIds + local.mediaIds + remote.mediaIds)
                var seen = Set<UUID>()
                merged.mediaIds = (attachments + cards.flatMap { $0.media.map(\.id) } +
                                   inline.sorted { $0.uuidString < $1.uuidString })
                    .filter { known.contains($0) && seen.insert($0).inserted }
            } else {
                conflicts.append(.cards)
            }
        } else {
            combine(\.mediaIds, field: .media)
            combine(\.itinerary, field: .itinerary)
            combine(\.noteCards, field: .cards)
            if let body = MarkdownMerge.merge(base: base.body, local: local.body, remote: remote.body) {
                merged.body = body
            } else if let choice {
                merged.body = choice == .local ? local.body : remote.body
            } else {
                conflicts.append(.body)
            }
            if !merged.cardContentMatchesMarkdown {
                if let choice {
                    let selected = choice == .local ? local : remote
                    merged.body = selected.body
                    merged.noteCards = selected.noteCards
                    merged.itinerary = selected.itinerary
                    merged.mediaIds = selected.mediaIds
                } else {
                    conflicts.append(.cards)
                }
            }
        }
        if let end = merged.endDate, end < merged.startDate {
            if let choice {
                let selected = choice == .local ? local : remote
                merged.startDate = selected.startDate
                merged.endDate = selected.endDate
            } else {
                conflicts.append(.startDate)
                conflicts.append(.endDate)
            }
        }
        if merged.kind != .trip && !merged.itinerary.isEmpty {
            if let choice {
                let selected = choice == .local ? local : remote
                merged.kind = selected.kind
                merged.itinerary = selected.itinerary
                if !merged.cardContentMatchesMarkdown {
                    merged.noteCards = selected.noteCards
                    merged.body = selected.body
                    merged.mediaIds = selected.mediaIds
                }
            } else {
                conflicts.append(.kind)
                conflicts.append(.itinerary)
            }
        }

        if conflicts.isEmpty { return .merged(merged) }
        var unique: [EntryConflictField] = []
        for field in conflicts where !unique.contains(field) { unique.append(field) }
        return conflict(unique)
    }
}

public enum MarkdownMerge {
    private struct Edit: Equatable {
        let range: Range<Int>
        let replacement: [String]

        func overlaps(_ other: Edit) -> Bool {
            if range.isEmpty && other.range.isEmpty { return range.lowerBound == other.range.lowerBound }
            if range.isEmpty {
                return other.range.lowerBound < range.lowerBound && range.lowerBound < other.range.upperBound
            }
            if other.range.isEmpty { return other.overlaps(self) }
            return range.overlaps(other.range)
        }
    }

    public static func merge(base: String, local: String, remote: String) -> String? {
        if local == remote || remote == base { return local }
        if local == base { return remote }

        let original = base.components(separatedBy: "\n")
        guard let ours = edits(from: original, to: local.components(separatedBy: "\n")),
              let theirs = edits(from: original, to: remote.components(separatedBy: "\n")) else { return nil }
        var combined = ours
        var lowerBound = 0
        for edit in theirs {
            while lowerBound < ours.count && ours[lowerBound].range.upperBound < edit.range.lowerBound {
                lowerBound += 1
            }
            var duplicate = false
            for existing in ours[lowerBound...] {
                if existing.range.lowerBound > edit.range.upperBound { break }
                if existing == edit {
                    duplicate = true
                } else if existing.overlaps(edit) {
                    return nil
                }
            }
            if !duplicate { combined.append(edit) }
        }

        var result: [String] = []
        var index = 0
        for edit in combined.sorted(by: {
            ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound)
        }) {
            result.append(contentsOf: original[index..<edit.range.lowerBound])
            result.append(contentsOf: edit.replacement)
            index = edit.range.upperBound
        }
        result.append(contentsOf: original[index...])
        return result.joined(separator: "\n")
    }

    private static func edits(from base: [String], to updated: [String]) -> [Edit]? {
        let prefix = zip(base, updated).prefix { $0 == $1 }.count
        let suffix = zip(base.dropFirst(prefix).reversed(), updated.dropFirst(prefix).reversed())
            .prefix { $0 == $1 }.count
        let old = Array(base[prefix..<(base.count - suffix)])
        let new = Array(updated[prefix..<(updated.count - suffix)])

        // Large rewrites are shown for manual review instead of blocking the synchronization process.
        guard old.count <= 4_000_000 / max(new.count, 1) else { return nil }
        let difference = new.difference(from: old)
        var removes: Set<Int> = []
        var inserts: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removes.insert(offset)
            case .insert(let offset, _, _): inserts.insert(offset)
            }
        }

        var edits: [Edit] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            let oldStart = oldIndex
            let newStart = newIndex
            while removes.contains(oldIndex) { oldIndex += 1 }
            while inserts.contains(newIndex) { newIndex += 1 }
            if oldStart != oldIndex || newStart != newIndex {
                edits.append(Edit(range: (prefix + oldStart)..<(prefix + oldIndex),
                                  replacement: Array(new[newStart..<newIndex])))
            }
            if oldIndex < old.count && newIndex < new.count {
                oldIndex += 1
                newIndex += 1
            }
        }
        return edits
    }
}
