import CryptoKit
import Foundation

public enum LibraryError: Error, LocalizedError {
    case unsupportedFormat, invalidEntry, invalidAsset, invalidChekiDetails, invalidItinerary, invalidMember
    case invalidMediaDetails, mediaInUse

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "此资料库版本暂不受支持。"
        case .invalidEntry: "请检查标题、日期和笔记归属。"
        case .invalidChekiDetails: "请选择拍立得的成员或团体，并填写拍摄日期。"
        case .invalidItinerary: "请为每项行程填写标题和有效的日期。行程只能保存在旅行笔记中。"
        case .invalidAsset: "媒体文件为空或无法读取。"
        case .mediaInUse: "此媒体仍被笔记或草稿引用。请先移除关联、正文中的媒体卡片或封面，再删除。"
        case .invalidMediaDetails: "请检查媒体的拍摄日期和成员。"
        case .invalidMember: "请填写成员姓名，并检查头像和应援色。"
        }
    }
}

public actor LibraryStore {
    public nonisolated let root: URL
    private let files = FileManager.default
    private var synchronizing = false

    public init(root: URL) { self.root = root }

    public func load() throws -> LibrarySnapshot {
        try prepare()
        let entries = try children("entries").map { try readEntry(at: $0) }
        let media = try children("media").map { try read(LibraryMedia.self, at: $0) }
        let members = try children("members").map { try read(Member.self, at: $0) }
        let groups = try children("groups").map { try read(IdolGroup.self, at: $0) }
        return LibrarySnapshot(entries: entries.sorted { ($0.startDate, $0.createdAt) > ($1.startDate, $1.createdAt) },
                               media: media.sorted { $0.createdAt > $1.createdAt },
                               members: members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                               groups: groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func readEntry(at folder: URL) throws -> LibraryEntry {
        let metadata = try read(EntryMetadata.self, at: folder.appending(path: "entry.json"))
        let body = try String(contentsOf: folder.appending(path: "body.md"), encoding: .utf8)
        return LibraryEntry(id: metadata.id, kind: metadata.kind, title: metadata.title,
                            startDate: metadata.startDate, endDate: metadata.endDate,
                            parentId: metadata.parentId, mediaIds: metadata.mediaIds,
                            body: body, createdAt: metadata.createdAt, itinerary: metadata.itinerary ?? [],
                            coverMediaId: metadata.coverMediaId, location: metadata.location, noteCards: metadata.noteCards)
    }

    private func entryDirectory(_ id: UUID) -> URL {
        root.appending(path: "entries/\(id.uuidString.lowercased())")
    }

    public func save(_ entry: LibraryEntry) throws {
        let snapshot = try load()
        let mediaIDs = Set(snapshot.media.map(\.id))
        var entry = entry
        let referenced = NoteMarkdownBlock.mediaIDs(in: entry.body)
        let additional = referenced.intersection(mediaIDs).subtracting(entry.mediaIds)
        entry.mediaIds.append(contentsOf: additional.sorted { $0.uuidString < $1.uuidString })
        try validate(entry, entries: snapshot.entries, mediaIDs: mediaIDs)
        try writeEntry(entry)
    }

    func libraryID() throws -> UUID {
        try read(Manifest.self, at: root.appending(path: "library.json")).libraryId
    }

    public func libraryTitle() throws -> String {
        try read(Manifest.self, at: root.appending(path: "library.json")).title
    }

    func writeMergedMetadata(_ snapshot: LibrarySnapshot, sources: [URL], destination: URL? = nil) throws {
        let target = destination ?? root
        for name in ["entries", "members", "groups", "media", "assets"] {
            try files.createDirectory(at: target.appending(path: name), withIntermediateDirectories: true)
        }
        func put<T: Encodable & Identifiable>(_ items: [T], in directory: String) throws where T.ID == UUID {
            for item in items {
                try write(item, to: target.appending(path: "\(directory)/\(item.id.uuidString.lowercased()).json"))
            }
        }
        try put(snapshot.members, in: "members")
        try put(snapshot.groups, in: "groups")
        try put(snapshot.media, in: "media")
        let mediaIDs = Set(snapshot.media.map(\.id))
        for entry in snapshot.entries {
            try validate(entry, entries: snapshot.entries, mediaIDs: mediaIDs)
            let relative = "entries/\(entry.id.uuidString.lowercased())"
            let timestamps = try sources.compactMap { source -> Date? in
                let path = source.appending(path: relative + "/entry.json")
                guard files.fileExists(atPath: path.path) else { return nil }
                return try read(EntryMetadata.self, at: path).updatedAt
            }
            let folder = target.appending(path: relative)
            try files.createDirectory(at: folder, withIntermediateDirectories: false)
            try write(EntryMetadata(entry, updatedAt: timestamps.max() ?? entry.createdAt),
                      to: folder.appending(path: "entry.json"))
            try Data(entry.body.utf8).write(to: folder.appending(path: "body.md"), options: .atomic)
        }
    }

    func beginSync() throws {
        guard !synchronizing else { throw LibrarySyncError.alreadyRunning }
        synchronizing = true
    }

    func endSync() { synchronizing = false }

    public func syncStatus() throws -> LibrarySyncStatus? {
        let path = root.appending(path: ".sync-status.json")
        guard files.fileExists(atPath: path.path) else { return nil }
        return try read(LibrarySyncStatus.self, at: path)
    }

    /// Older sync anchors don't have a baseline until their next successful sync.
    public func hasUnsyncedMetadata() throws -> Bool? {
        guard let baseline = try syncStatus()?.metadataDigest else { return nil }
        return try Self.metadataDigest(for: load()) != baseline
    }

    private static func metadataDigest(for snapshot: LibrarySnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        func append<T: Identifiable & Encodable>(_ records: [T]) throws where T.ID == UUID {
            for record in records.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try Task.checkCancellation()
                hash.update(data: try encoder.encode(record))
                hash.update(data: Data([0]))
            }
            hash.update(data: Data([0]))
        }
        try append(snapshot.entries)
        try append(snapshot.media)
        try append(snapshot.members)
        try append(snapshot.groups)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func bindRestoredLibrary(to connectionID: String, revision: GitRevision) throws {
        try prepare()
        guard try syncStatus() == nil else { throw LibrarySyncError.differentConnection }
        let digest = try Self.metadataDigest(for: load())
        try write(LibrarySyncStatus(connectionID: connectionID, revision: revision, syncedAt: .now, metadataDigest: digest),
                  to: root.appending(path: ".sync-status.json"))
    }

    func applySyncedLibrary(base: LibrarySnapshot, remote: LibrarySnapshot, from source: URL,
                            revision: GitRevision, connectionID: String, report: SyncAttachmentReport,
                            resolutions: [String: SyncConflictChoice]) throws -> [LibrarySyncConflict] {
        let current = try load()
        let plan = try SnapshotMerge.plan(base: base, local: current, remote: remote, resolutions: resolutions)
        if !plan.conflicts.isEmpty { return plan.conflicts }

        let stage = root.deletingLastPathComponent().appending(path: ".kinen-apply-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { if files.fileExists(atPath: stage.path) { try? files.removeItem(at: stage) } }
        try files.copyItem(at: root.appending(path: "library.json"), to: stage.appending(path: "library.json"))
        try files.copyItem(at: root.appending(path: ".drafts"), to: stage.appending(path: ".drafts"))
        try writeMergedMetadata(plan.snapshot, sources: [root, source], destination: stage)
        try LibraryBackup.copyReferencedAssets(plan.snapshot.media.flatMap(\.assets), from: [root, source], to: stage)
        let status = LibrarySyncStatus(connectionID: connectionID, revision: revision, syncedAt: .now,
                                       attachments: report, metadataDigest: try Self.metadataDigest(for: remote))
        try write(status, to: stage.appending(path: ".sync-status.json"))
        _ = try files.replaceItemAt(root, withItemAt: stage)
        return []
    }

    private func validate(_ entry: LibraryEntry, entries: [LibraryEntry], mediaIDs: Set<UUID>) throws {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.endDate.map({ $0 >= entry.startDate }) ?? true,
              entries.filter({ $0.parentId == entry.id }).allSatisfy({ entry.kind.allowsChild($0.kind) }),
              Set(entry.mediaIds).isSubset(of: mediaIDs) else { throw LibraryError.invalidEntry }
        if let parentId = entry.parentId {
            guard parentId != entry.id,
                  let parent = entries.first(where: { $0.id == parentId }),
                  parent.kind.allowsChild(entry.kind) else { throw LibraryError.invalidEntry }
        }

        guard entry.itinerary.isEmpty || (
            entry.kind == .trip && Set(entry.itinerary.map(\.id)).count == entry.itinerary.count &&
            entry.itinerary.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                Self.isValidDay($0.date) && ($0.time.map(Self.isValidTime) ?? true)
            }
        ) else { throw LibraryError.invalidItinerary }

    }

    private func writeEntry(_ entry: LibraryEntry, updatedAt: Date = .now) throws {
        let target = entryDirectory(entry.id)
        let stage = root.appending(path: ".entry-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        try write(EntryMetadata(entry, updatedAt: updatedAt), to: stage.appending(path: "entry.json"))
        try Data(entry.body.utf8).write(to: stage.appending(path: "body.md"), options: .atomic)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: stage)
        } else {
            try files.moveItem(at: stage, to: target)
        }
    }

    /// Returns true when the quick edit was added to an existing unpublished draft.
    public func appendTravelStop(_ stop: TravelStop, to id: UUID) throws -> Bool {
        try updateEntryFromDetail(id) { entry in
            guard entry.kind == .trip, Self.isValidDay(stop.date),
                  !stop.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  stop.time.map(Self.isValidTime) ?? true else { throw LibraryError.invalidItinerary }
            if let existing = entry.itinerary.first(where: { $0.id == stop.id }) {
                guard existing == stop else { throw LibraryError.invalidItinerary }
                return
            }
            if let cards = entry.noteCards {
                guard entry.cardContentMatchesMarkdown else { throw LibraryError.invalidEntry }
                entry.replaceNoteCards(cards + [NoteCard(kind: .itinerary, stop: stop)])
            } else {
                entry.itinerary.append(stop)
            }
        }
    }

    /// Returns true when the quick edit was added to an existing unpublished draft.
    public func attachExistingMedia(_ ids: [UUID], to entryID: UUID) throws -> Bool {
        try updateEntryFromDetail(entryID) { entry in
            var seen = Set(entry.mediaIds)
            for id in ids where seen.insert(id).inserted {
                let record = try read(LibraryMedia.self, at: recordURL("media", id))
                guard record.id == id else { throw LibraryError.invalidAsset }
                entry.mediaIds.append(id)
            }
        }
    }

    /// Returns true when the new parent was applied to an existing unpublished draft.
    public func moveEntry(_ id: UUID, to parentID: UUID?) throws -> Bool {
        try updateEntryFromDetail(id) { entry in
            if let parentID {
                guard parentID != id else { throw LibraryError.invalidEntry }
                let folder = entryDirectory(parentID)
                guard files.fileExists(atPath: folder.path) else { throw LibraryError.invalidEntry }
                let parent = try readEntry(at: folder)
                guard parent.id == parentID, parent.kind.allowsChild(entry.kind) else {
                    throw LibraryError.invalidEntry
                }
            }
            entry.parentId = parentID
        }
    }

    private func updateEntryFromDetail(_ id: UUID, update: (inout LibraryEntry) throws -> Void) throws -> Bool {
        try prepare()
        let published = try readEntry(at: entryDirectory(id))
        guard published.id == id else { throw LibraryError.invalidEntry }
        let path = recordURL(".drafts", id)
        let draft = files.fileExists(atPath: path.path) ? try read(EntryDraft.self, at: path) : nil
        var entry = draft?.entry ?? published
        guard entry.id == id else { throw LibraryError.invalidEntry }
        let before = entry
        try update(&entry)
        if entry != before {
            if draft != nil { try saveDraft(entry) }
            else { try writeEntry(entry) }
        }
        return draft != nil
    }

    public func drafts() throws -> [EntryDraft] {
        try prepare()
        return try children(".drafts")
            .map { try read(EntryDraft.self, at: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveDraft(_ entry: LibraryEntry) throws {
        try Task.checkCancellation()
        try prepare()
        try write(EntryDraft(entry: entry, updatedAt: .now), to: recordURL(".drafts", entry.id))
    }

    public func discardDraft(_ id: UUID) throws {
        let url = recordURL(".drafts", id)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    public func publishDraft(_ entry: LibraryEntry) throws {
        try save(entry)
        try discardDraft(entry.id)
    }

    @discardableResult
    public func addMember(name: String) throws -> Member {
        try saveMember(id: nil, name: name, avatarJPEG: nil, colors: nil)
    }

    @discardableResult
    public func saveMember(id: UUID?, name: String, avatarJPEG: Data?,
                           colors: MemberSupportColors?, aliases: [String]? = nil,
                           archived: Bool? = nil) throws -> Member {
        try prepare()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (avatarJPEG?.count ?? 0) <= 128 * 1024 else { throw LibraryError.invalidMember }
        func normalize(_ value: String?) throws -> String? {
            guard let value else { return nil }
            guard value.utf8.count == 6, value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw LibraryError.invalidMember }
            return value.uppercased()
        }
        let first = try normalize(colors?.first)
        let second = try normalize(colors?.second)
        var member: Member
        if let id {
            member = try read(Member.self, at: recordURL("members", id))
        } else {
            member = Member(name: name)
        }
        let previous = member
        member.name = name
        member.avatarJPEG = avatarJPEG
        member.supportColors = first == nil && second == nil ? nil : MemberSupportColors(first: first, second: second)
        if let aliases {
            var seen = Set<String>()
            member.aliases = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if let archived { member.archived = archived }
        if id != nil && member == previous { return previous }
        member.updatedAt = .now
        try write(member, to: recordURL("members", member.id))
        return member
    }

    public func addGroup(name: String) throws -> IdolGroup {
        try saveGroup(id: nil, name: name)
    }

    @discardableResult
    public func saveGroup(id: UUID?, name: String) throws -> IdolGroup {
        try prepare()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidEntry }
        var group = try id.map { try read(IdolGroup.self, at: recordURL("groups", $0)) } ?? IdolGroup(name: name)
        if id != nil && group.name == name { return group }
        group.name = name
        try write(group, to: recordURL("groups", group.id))
        return group
    }

    @discardableResult
    public func importMedia(from source: URL, filename: String, mimeType: String,
                            kind: MediaKind, captureDate: String?, memberIds: [UUID],
                            chekiSubject: ChekiSubject? = nil, note: String = "",
                            quarterTurns: Int = 0, corrected: (source: URL, corners: PhotoQuad)? = nil,
                            enhanced: (source: URL, adjustments: ChekiAdjustments)? = nil, attachTo entryID: UUID? = nil) throws -> LibraryMedia {
        try prepare()
        var entry: LibraryEntry?
        if let entryID {
            let folder = entryDirectory(entryID)
            guard files.fileExists(atPath: folder.path) else { throw LibraryError.invalidEntry }
            let existing = try readEntry(at: folder)
            guard existing.id == entryID else { throw LibraryError.invalidEntry }
            entry = existing
        }
        let id = UUID()
        let attribution = kind == .cheki
            ? try chekiAttribution(chekiSubject, captureDate: captureDate, id: id, filename: filename)
            : nil
        let original = try installAsset(source: source, filename: filename, mimeType: mimeType,
                                        storedFilename: attribution?.filename)
        do {
            var item = LibraryMedia(id: id, kind: kind, captureDate: captureDate,
                                    memberIds: Array(Set(attribution?.memberIds ?? memberIds)).sorted { $0.uuidString < $1.uuidString },
                                    groupId: attribution?.groupId, note: note, quarterTurns: Self.normalizedTurns(quarterTurns),
                                    original: original, createdAt: .now, updatedAt: .now)
            if kind == .cheki, let corrected {
                item.corrected = try installAsset(source: corrected.source, filename: "拍立得校正图.jpg", mimeType: "image/jpeg")
                item.correction = corrected.corners
            }
            if kind == .cheki, let enhanced {
                item.enhanced = try installAsset(source: enhanced.source, filename: "拍立得调整图.jpg", mimeType: "image/jpeg")
                item.adjustments = enhanced.adjustments
            }
            try write(item, to: recordURL("media", item.id))
            if var entry {
                entry.mediaIds.append(item.id)
                do { try writeEntry(entry) }
                catch {
                    try? files.removeItem(at: recordURL("media", item.id))
                    throw error
                }
            }
            return item
        } catch {
            if attribution != nil { try? files.removeItem(at: assetURL(original)) }
            throw error
        }
    }

    public func deleteMedia(id: UUID) throws {
        guard !synchronizing else { throw LibrarySyncError.alreadyRunning }
        let snapshot = try load()
        guard let item = snapshot.mediaByID[id] else { return }
        func referencesMedia(_ entry: LibraryEntry) -> Bool {
            entry.coverMediaId == id || entry.mediaIds.contains(id) ||
                entry.noteCards?.contains { $0.media.contains { $0.id == id } } == true ||
                NoteMarkdownBlock.mediaIDs(in: entry.body).contains(id)
        }
        guard !snapshot.entries.contains(where: referencesMedia),
              try !drafts().contains(where: { referencesMedia($0.entry) }) else {
            throw LibraryError.mediaInUse
        }

        let retained = Set(snapshot.media.lazy.filter { $0.id != id }
            .flatMap(\.assets).map { self.assetURL($0) })
        try files.removeItem(at: recordURL("media", id))
        for url in Set(item.assets.map { assetURL($0) }).subtracting(retained) {
            // The record has been removed. A failed file cleanup can leave an unreferenced asset.
            try? files.removeItem(at: url)
        }
    }

    public func setChekiCorrection(id: UUID, corrected: (source: URL, corners: PhotoQuad)?,
                                   enhanced: (source: URL, adjustments: ChekiAdjustments)? = nil) throws {
        try prepare()
        let record = recordURL("media", id)
        var item = try read(LibraryMedia.self, at: record)
        guard item.kind == .cheki else { throw LibraryError.invalidChekiDetails }
        item.corrected = try corrected.map {
            try installAsset(source: $0.source, filename: "拍立得校正图.jpg", mimeType: "image/jpeg")
        }
        item.correction = corrected?.corners
        item.enhanced = try enhanced.map {
            try installAsset(source: $0.source, filename: "拍立得调整图.jpg", mimeType: "image/jpeg")
        }
        item.adjustments = enhanced?.adjustments
        item.updatedAt = .now
        try write(item, to: record)
    }

    public func setChekiAdjustments(id: UUID, baseSHA256: String,
                                    enhanced: (source: URL, adjustments: ChekiAdjustments)?) throws {
        try prepare()
        let record = recordURL("media", id)
        var item = try read(LibraryMedia.self, at: record)
        guard item.id == id, item.kind == .cheki,
              (item.corrected ?? item.original).sha256 == baseSHA256 else {
            throw LibraryError.invalidChekiDetails
        }
        if enhanced == nil, item.enhanced == nil { return }
        item.enhanced = try enhanced.map {
            try installAsset(source: $0.source, filename: "拍立得调整图.jpg", mimeType: "image/jpeg")
        }
        item.adjustments = enhanced?.adjustments
        item.updatedAt = .now
        try write(item, to: record)
    }

    public func updateMediaDetails(id: UUID, captureDate: String?, memberIds: Set<UUID>,
                                   note: String) throws {
        try prepare()
        let url = recordURL("media", id)
        var item = try read(LibraryMedia.self, at: url)
        guard item.kind != .cheki, captureDate.map(Self.isValidDay) ?? true else {
            throw LibraryError.invalidMediaDetails
        }
        let existing = Set(item.memberIds)
        for newID in memberIds.subtracting(existing) {
            let member = try read(Member.self, at: recordURL("members", newID))
            guard member.id == newID, !member.archived else { throw LibraryError.invalidMediaDetails }
        }
        guard item.captureDate != captureDate || existing != memberIds || item.note != note else { return }
        item.captureDate = captureDate
        item.memberIds = memberIds.sorted { $0.uuidString < $1.uuidString }
        item.note = note
        item.updatedAt = .now
        try write(item, to: url)
    }

    private func installAsset(source: URL, filename: String, mimeType: String,
                              storedFilename: String? = nil) throws -> MediaAsset {
        let stage = root.appending(path: ".media-\(UUID().uuidString)")
        try files.copyItem(at: source, to: stage)
        defer { try? files.removeItem(at: stage) }
        let handle = try FileHandle(forReadingFrom: stage)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: UInt64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
            size += UInt64(bytes.count)
        }
        guard size > 0 else { throw LibraryError.invalidAsset }
        let asset = MediaAsset(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                               byteLength: size, mimeType: mimeType, originalFilename: filename,
                               storedFilename: storedFilename)
        let target = assetURL(asset)
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: target.path) { try files.moveItem(at: stage, to: target) }
        return asset
    }

    public nonisolated func displayURL(for item: LibraryMedia) -> URL {
        assetURL(displayAsset(for: item))
    }

    public nonisolated func displayAsset(for item: LibraryMedia) -> MediaAsset {
        for candidate in [item.enhanced, item.corrected].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: assetURL(candidate).path) { return candidate }
        }
        return item.original
    }

    public func updateCheki(id: UUID, subject: ChekiSubject, captureDate: String,
                            note: String, quarterTurns: Int) throws {
        try prepare()
        let record = recordURL("media", id)
        var item = try read(LibraryMedia.self, at: record)
        guard item.kind == .cheki else { throw LibraryError.invalidChekiDetails }
        let attribution = try chekiAttribution(subject, captureDate: captureDate, id: id,
                                               filename: item.original.originalFilename)
        let previousAsset = item.original
        let updatedAsset = MediaAsset(sha256: previousAsset.sha256, byteLength: previousAsset.byteLength,
                                      mimeType: previousAsset.mimeType,
                                      originalFilename: previousAsset.originalFilename,
                                      storedFilename: attribution.filename)
        let previousURL = assetURL(previousAsset)
        let updatedURL = assetURL(updatedAsset)
        let moved = previousURL != updatedURL && files.fileExists(atPath: previousURL.path)
        if moved {
            try files.createDirectory(at: updatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the previous path valid until the atomic metadata write succeeds.
            if files.fileExists(atPath: updatedURL.path) { try files.removeItem(at: updatedURL) }
            try files.linkItem(at: previousURL, to: updatedURL)
        }
        item.captureDate = captureDate
        item.memberIds = attribution.memberIds
        item.groupId = attribution.groupId
        item.note = note
        item.quarterTurns = Self.normalizedTurns(quarterTurns)
        // Preserve the last known asset path when the asset has not been downloaded.
        if previousURL == updatedURL || moved { item.original = updatedAsset }
        item.updatedAt = .now
        do {
            try write(item, to: record)
        } catch {
            if moved { try? files.removeItem(at: updatedURL) }
            throw error
        }
        if moved, previousAsset.storedFilename != nil { try? files.removeItem(at: previousURL) }
    }

    private struct ChekiAttribution {
        let memberIds: [UUID]
        let groupId: UUID?
        let filename: String
    }

    private func chekiAttribution(_ subject: ChekiSubject?, captureDate: String?, id: UUID,
                                  filename: String) throws -> ChekiAttribution {
        guard let subject, let captureDate, Self.isValidDay(captureDate) else {
            throw LibraryError.invalidChekiDetails
        }
        let subjectId: UUID
        let memberIds: [UUID]
        let groupId: UUID?
        switch subject {
        case .member(let memberId):
            _ = try read(Member.self, at: recordURL("members", memberId))
            subjectId = memberId
            memberIds = [memberId]
            groupId = nil
        case .group(let selectedGroupId):
            _ = try read(IdolGroup.self, at: recordURL("groups", selectedGroupId))
            subjectId = selectedGroupId
            memberIds = []
            groupId = selectedGroupId
        }
        let suffix = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let base = "\(subjectId.uuidString.lowercased())_\(captureDate)_\(id.uuidString.lowercased())"
        let validSuffix = !suffix.isEmpty && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0)
        }
        return ChekiAttribution(memberIds: memberIds, groupId: groupId, filename: validSuffix ? "\(base).\(suffix)" : base)
    }

    private static func normalizedTurns(_ value: Int) -> Int? {
        let turns = (value % 4 + 4) % 4
        return turns == 0 ? nil : turns
    }

    public nonisolated func assetURL(_ asset: MediaAsset) -> URL {
        if let filename = asset.storedFilename, !filename.isEmpty,
           filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") {
            return root.appending(path: "assets/cheki").appending(path: filename)
        }
        return root.appending(path: "assets/sha256/\(asset.sha256.prefix(2))/\(asset.sha256)")
    }

    private static func isValidTime(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              let hour = Int(value.prefix(2)), let minute = Int(value.suffix(2)),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return false }
        return value == String(format: "%02d:%02d", hour, minute)
    }

    private static func isValidDay(_ day: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return false }
        return formatter.string(from: date) == day
    }

    private func prepare() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appending(path: "library.json")
        if files.fileExists(atPath: manifest.path) {
            guard try read(Manifest.self, at: manifest).formatVersion == 1 else {
                throw LibraryError.unsupportedFormat
            }
        } else {
            try write(Manifest(formatVersion: 1, libraryId: UUID(), title: "記念撮影"), to: manifest)
        }
        for directory in ["members", "groups", "entries", "media", "assets", ".drafts"] {
            try files.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
        }
    }

    private func children(_ directory: String) throws -> [URL] {
        try files.contentsOfDirectory(at: root.appending(path: directory),
                                      includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { directory == "entries" ? UUID(uuidString: $0.lastPathComponent) != nil : $0.pathExtension == "json" }
    }

    private func recordURL(_ directory: String, _ id: UUID) -> URL {
        root.appending(path: "\(directory)/\(id.uuidString.lowercased()).json")
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}

private struct Manifest: Codable {
    let formatVersion: Int
    let libraryId: UUID
    let title: String
}

private struct EntryMetadata: Codable {
    let id: UUID
    let kind: EntryKind
    let title: String
    let startDate: String
    let endDate: String?
    let parentId: UUID?
    let mediaIds: [UUID]
    let coverMediaId: UUID?
    let location: String?
    let itinerary: [TravelStop]?
    let noteCards: [NoteCard]?
    let timeZone: String
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: LibraryEntry, updatedAt: Date) {
        id = entry.id
        kind = entry.kind
        title = entry.title
        startDate = entry.startDate
        endDate = entry.endDate
        parentId = entry.parentId
        mediaIds = entry.mediaIds
        coverMediaId = entry.coverMediaId
        location = entry.location
        itinerary = entry.itinerary.isEmpty ? nil : entry.itinerary
        noteCards = entry.noteCards
        timeZone = TimeZone.current.identifier
        createdAt = entry.createdAt
        self.updatedAt = updatedAt
    }
}
