import Foundation

public enum EntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case memory, live, trip, journal
    public var id: String { rawValue }

    public func allowsChild(_ child: Self) -> Bool {
        (self == .trip && (child == .live || child == .memory)) ||
        (self == .live && child == .memory)
    }
}

public enum MediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cheki, portrait, photo, video
    public var id: String { rawValue }
}

public struct LibraryEntry: Identifiable, Sendable {
    public let id: UUID
    public var kind: EntryKind
    public var title: String
    public var startDate: String
    public var endDate: String?
    public var parentId: UUID?
    public var mediaIds: [UUID]
    public var body: String
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: EntryKind = .journal, title: String = "",
                startDate: String = LocalDay.today(), endDate: String? = nil,
                parentId: UUID? = nil, mediaIds: [UUID] = [], body: String = "",
                createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.parentId = parentId
        self.mediaIds = mediaIds
        self.body = body
        self.createdAt = createdAt
    }
}

public enum LocalDay {
    public static func today() -> String { string(from: .now) }

    public static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct Member: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    public let archived: Bool
    public let aliases: [String]

    public init(name: String) {
        let now = Date.now
        id = UUID()
        self.name = name
        createdAt = now
        updatedAt = now
        archived = false
        aliases = []
    }
}

public struct MediaAsset: Codable, Sendable {
    public let sha256: String
    public let byteLength: UInt64
    public let mimeType: String
    public let originalFilename: String
}

public struct LibraryMedia: Codable, Identifiable, Sendable {
    public let id: UUID
    public var kind: MediaKind
    public var captureDate: String?
    public var memberIds: [UUID]
    public var note: String
    public let original: MediaAsset
    public let createdAt: Date
    public var updatedAt: Date
}

public struct LibrarySnapshot: Sendable {
    public let entries: [LibraryEntry]
    public let media: [LibraryMedia]
    public let members: [Member]

    public init(entries: [LibraryEntry] = [], media: [LibraryMedia] = [], members: [Member] = []) {
        self.entries = entries
        self.media = media
        self.members = members
    }

    public func chekiCount(for member: UUID? = nil) -> Int {
        media.count { item in
            item.kind == .cheki && (member.map { item.memberIds.contains($0) } ?? true)
        }
    }
}
