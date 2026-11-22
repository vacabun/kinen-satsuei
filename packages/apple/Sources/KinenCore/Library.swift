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

public struct TravelStop: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var date: String
    public var time: String?
    public var title: String
    public var location: String
    public var note: String

    public init(date: String, time: String? = nil, title: String = "", location: String = "", note: String = "") {
        id = UUID()
        self.date = date
        self.time = time
        self.title = title
        self.location = location
        self.note = note
    }
}

public struct LibraryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: EntryKind
    public var title: String
    public var startDate: String
    public var endDate: String?
    public var parentId: UUID?
    public var mediaIds: [UUID]
    public var coverMediaId: UUID?
    public var location: String?
    public var body: String
    public var noteCards: [NoteCard]?
    public let createdAt: Date
    private var storedItinerary: [TravelStop]?

    public var itinerary: [TravelStop] {
        get { storedItinerary ?? [] }
        set { storedItinerary = newValue.isEmpty ? nil : newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, startDate, endDate, parentId, mediaIds, coverMediaId, location, body, noteCards, createdAt
        case storedItinerary = "itinerary"
    }

    public init(id: UUID = UUID(), kind: EntryKind = .journal, title: String = "",
                startDate: String = LocalDay.today(), endDate: String? = nil,
                parentId: UUID? = nil, mediaIds: [UUID] = [], body: String = "",
                createdAt: Date = .now, itinerary: [TravelStop] = [], coverMediaId: UUID? = nil,
                location: String? = nil, noteCards: [NoteCard]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.parentId = parentId
        self.mediaIds = mediaIds
        self.coverMediaId = coverMediaId
        self.location = location
        self.body = body
        self.noteCards = noteCards
        self.createdAt = createdAt
        self.itinerary = itinerary
    }
}

public struct EntryDraft: Codable, Identifiable, Sendable {
    public let entry: LibraryEntry
    public let updatedAt: Date

    public var id: UUID { entry.id }
}

public enum LocalDay {
    public static func today() -> String { string(from: .now) }

    public static func date(from value: String) -> Date? { formatter().date(from: value) }

    public static func string(from date: Date) -> String { formatter().string(from: date) }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

public struct MemberSupportColors: Codable, Equatable, Sendable {
    public let first: String?
    public let second: String?

    public init(first: String?, second: String?) {
        self.first = first
        self.second = second
    }
}

public struct Member: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var archived: Bool
    public var aliases: [String]
    public var avatarJPEG: Data?
    public var supportColors: MemberSupportColors?

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

public struct IdolGroup: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(name: String) {
        id = UUID()
        self.name = name
        createdAt = .now
    }
}

public enum ChekiSubject: Hashable, Sendable {
    case member(UUID)
    case group(UUID)
}

public struct MediaAsset: Codable, Sendable {
    public let sha256: String
    public let byteLength: UInt64
    public let mimeType: String
    public let originalFilename: String
    public let storedFilename: String?
}

public struct ChekiAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var glare: Double

    // nil identifies older edits that used a global highlight curve.
    public var glareExclusions: [GlarePoint]?
    public var glareInclusions: [GlarePoint]?

    public struct GlarePoint: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let radius: Double?

        public init(x: Double, y: Double, radius: Double? = nil) {
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0, glare: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.glare = glare
    }

    public var isNeutral: Bool { exposure == 0 && contrast == 0 && saturation == 0 && glare == 0 }
}

public struct LibraryMedia: Codable, Identifiable, Sendable {
    public let id: UUID
    public var kind: MediaKind
    public var captureDate: String?
    public var memberIds: [UUID]
    public var groupId: UUID?
    public var note: String
    public var quarterTurns: Int?
    public internal(set) var original: MediaAsset
    public internal(set) var corrected: MediaAsset? = nil
    public internal(set) var correction: PhotoQuad? = nil
    public internal(set) var enhanced: MediaAsset? = nil
    public internal(set) var adjustments: ChekiAdjustments? = nil

    public var assets: [MediaAsset] {
        [original] + [corrected, enhanced].compactMap { $0 }
    }

    public var chekiSubject: ChekiSubject? {
        if let groupId { return .group(groupId) }
        guard memberIds.count == 1, let memberId = memberIds.first else { return nil }
        return .member(memberId)
    }
    public let createdAt: Date
    public var updatedAt: Date
}

public struct LibrarySnapshot: Sendable {
    public let entries: [LibraryEntry]
    public let media: [LibraryMedia]
    public let members: [Member]
    public let groups: [IdolGroup]
    public let mediaByID: [UUID: LibraryMedia]
    public let entriesByID: [UUID: LibraryEntry]
    public let membersByID: [UUID: Member]
    public let groupsByID: [UUID: IdolGroup]
    public let chekiMedia: [LibraryMedia]
    private let entriesByMediaID: [UUID: [LibraryEntry]]
    private let chekisBySubject: [ChekiSubject: [LibraryMedia]]

    public init(entries: [LibraryEntry] = [], media: [LibraryMedia] = [], members: [Member] = [], groups: [IdolGroup] = []) {
        self.entries = entries
        self.media = media
        self.members = members
        self.groups = groups
        mediaByID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var linkedEntries: [UUID: [LibraryEntry]] = [:]
        for entry in entries {
            for mediaID in Set(entry.mediaIds) {
                linkedEntries[mediaID, default: []].append(entry)
            }
        }
        entriesByMediaID = linkedEntries
        membersByID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        chekiMedia = media.filter { $0.kind == .cheki }
        var bySubject: [ChekiSubject: [LibraryMedia]] = [:]
        for item in chekiMedia {
            for id in Set(item.memberIds) { bySubject[.member(id), default: []].append(item) }
            if let group = item.groupId { bySubject[.group(group), default: []].append(item) }
        }
        chekisBySubject = bySubject
    }

    public func entries(linkingMedia id: UUID) -> [LibraryEntry] {
        entriesByMediaID[id] ?? []
    }

    public func chekis(for subject: ChekiSubject) -> [LibraryMedia] {
        chekisBySubject[subject] ?? []
    }

    public func chekiCount(for member: UUID? = nil) -> Int {
        if let member { return chekis(for: .member(member)).count }
        return chekiMedia.count
    }
}
