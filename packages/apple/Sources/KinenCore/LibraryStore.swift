import CryptoKit
import Foundation

public enum LibraryError: Error, LocalizedError {
    case unsupportedFormat, invalidEntry, invalidAsset

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "此资料库版本暂不受支持。"
        case .invalidEntry: "请检查标题、日期和手帐归属。"
        case .invalidAsset: "媒体文件为空或无法读取。"
        }
    }
}

public actor LibraryStore {
    public nonisolated let root: URL
    private let files = FileManager.default

    public init(root: URL) { self.root = root }

    public func load() throws -> LibrarySnapshot {
        try prepare()
        let entries = try children("entries").map { folder in
            let metadata = try read(EntryMetadata.self, at: folder.appending(path: "entry.json"))
            let body = try String(contentsOf: folder.appending(path: "body.md"), encoding: .utf8)
            return LibraryEntry(id: metadata.id, kind: metadata.kind, title: metadata.title,
                                startDate: metadata.startDate, endDate: metadata.endDate,
                                parentId: metadata.parentId, mediaIds: metadata.mediaIds,
                                body: body, createdAt: metadata.createdAt)
        }
        let media = try children("media").map { try read(LibraryMedia.self, at: $0) }
        let members = try children("members").map { try read(Member.self, at: $0) }
        return LibrarySnapshot(entries: entries.sorted { ($0.startDate, $0.createdAt) > ($1.startDate, $1.createdAt) },
                               media: media.sorted { $0.createdAt > $1.createdAt },
                               members: members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    public func save(_ entry: LibraryEntry) throws {
        let snapshot = try load()
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.endDate.map({ $0 >= entry.startDate }) ?? true,
              snapshot.entries.filter({ $0.parentId == entry.id }).allSatisfy({ entry.kind.allowsChild($0.kind) }),
              Set(entry.mediaIds).isSubset(of: Set(snapshot.media.map(\.id))) else { throw LibraryError.invalidEntry }
        if let parentId = entry.parentId {
            guard parentId != entry.id,
                  let parent = snapshot.entries.first(where: { $0.id == parentId }),
                  parent.kind.allowsChild(entry.kind) else { throw LibraryError.invalidEntry }
        }

        let target = root.appending(path: "entries/\(entry.id.uuidString.lowercased())")
        let stage = root.appending(path: ".entry-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        try write(EntryMetadata(entry), to: stage.appending(path: "entry.json"))
        try Data(entry.body.utf8).write(to: stage.appending(path: "body.md"), options: .atomic)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: stage)
        } else {
            try files.moveItem(at: stage, to: target)
        }
    }

    public func addMember(name: String) throws {
        try prepare()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidEntry }
        let member = Member(name: name)
        try write(member, to: recordURL("members", member.id))
    }

    @discardableResult
    public func importMedia(from source: URL, filename: String, mimeType: String,
                            kind: MediaKind, captureDate: String?, memberIds: [UUID]) throws -> LibraryMedia {
        try prepare()
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
                               byteLength: size, mimeType: mimeType, originalFilename: filename)
        let target = assetURL(asset)
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: target.path) { try files.moveItem(at: stage, to: target) }
        let item = LibraryMedia(id: UUID(), kind: kind, captureDate: captureDate,
                                memberIds: Array(Set(memberIds)).sorted { $0.uuidString < $1.uuidString },
                                note: "", original: asset, createdAt: .now, updatedAt: .now)
        try write(item, to: recordURL("media", item.id))
        return item
    }

    public nonisolated func assetURL(_ asset: MediaAsset) -> URL {
        root.appending(path: "assets/sha256/\(asset.sha256.prefix(2))/\(asset.sha256)")
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
        for directory in ["members", "entries", "media", "assets"] {
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
    let timeZone: String
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: LibraryEntry) {
        id = entry.id
        kind = entry.kind
        title = entry.title
        startDate = entry.startDate
        endDate = entry.endDate
        parentId = entry.parentId
        mediaIds = entry.mediaIds
        timeZone = TimeZone.current.identifier
        createdAt = entry.createdAt
        updatedAt = .now
    }
}
