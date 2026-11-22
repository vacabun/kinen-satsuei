import Foundation

public struct LibraryQuery: Sendable {
    private let terms: [String]

    public init(_ input: String) {
        terms = input.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ fields: [String]) -> Bool {
        terms.allSatisfy { term in
            fields.contains { field in
                field.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    public func matches(_ entry: LibraryEntry) -> Bool {
        if isEmpty { return true }
        let fields = [entry.title, entry.body, entry.startDate, entry.endDate ?? ""]
        let itinerary = entry.itinerary.flatMap { [$0.title, $0.location, $0.note, $0.date, $0.time ?? ""] }
        return matches(fields + itinerary)
    }
}

public struct MediaSearch: Sendable {
    private let membersByID: [UUID: Member]
    private let groupsByID: [UUID: IdolGroup]

    public init(snapshot: LibrarySnapshot) {
        membersByID = snapshot.membersByID
        groupsByID = snapshot.groupsByID
    }

    public func matches(_ item: LibraryMedia, query: LibraryQuery) -> Bool {
        if query.isEmpty { return true }
        let attributedMembers = item.memberIds.compactMap { membersByID[$0] }
        let memberFields = attributedMembers.flatMap { [$0.name] + $0.aliases }
        let group = item.groupId.flatMap { groupsByID[$0]?.name }
        return query.matches([item.note, item.captureDate ?? "日期未知", group ?? ""] + memberFields)
    }

    public func names(for item: LibraryMedia) -> [String] {
        let members = item.memberIds.compactMap { membersByID[$0]?.name }
        guard let group = item.groupId.flatMap({ groupsByID[$0]?.name }) else { return members }
        return members + [group]
    }
}
