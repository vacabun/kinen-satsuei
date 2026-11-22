import Foundation

public enum CollectionDateBasis: String, CaseIterable, Identifiable, Sendable {
    case capture, added

    public var id: Self { self }

    public func trend(for media: [LibraryMedia], timeZone: TimeZone = .current) -> CollectionTrend {
        let calendar = Self.calendar(in: timeZone)
        var counts: [Int: [Int: [Int: Int]]] = [:]
        var unknownCount = 0

        for item in media where item.kind == .cheki {
            if let date = components(for: item, calendar: calendar),
               let year = date.year, let month = date.month, let day = date.day {
                counts[year, default: [:]][month, default: [:]][day, default: 0] += 1
            } else {
                unknownCount += 1
            }
        }
        return CollectionTrend(counts: counts, unknownCount: unknownCount)
    }

    public func photos(on day: CollectionDay, from media: [LibraryMedia], timeZone: TimeZone = .current) -> [LibraryMedia] {
        let calendar = Self.calendar(in: timeZone)
        let target = DateComponents(year: day.year, month: day.month, day: day.day)
        return media.filter { $0.kind == .cheki && components(for: $0, calendar: calendar) == target }
    }

    private func components(for item: LibraryMedia, calendar: Calendar) -> DateComponents? {
        switch self {
        case .capture:
            return item.captureDate.flatMap(Self.captureComponents)
        case .added:
            return calendar.dateComponents([.year, .month, .day], from: item.createdAt)
        }
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func captureComponents(_ day: String) -> DateComponents? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let date = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(year: year, month: month, day: date)
        return components.isValidDate(in: calendar) ? components : nil
    }
}

public struct CollectionTrend: Sendable {
    private let counts: [Int: [Int: [Int: Int]]]
    public let unknownCount: Int

    init(counts: [Int: [Int: [Int: Int]]], unknownCount: Int) {
        self.counts = counts
        self.unknownCount = unknownCount
    }

    public var years: [Int] { counts.keys.sorted(by: >) }

    public func months(in year: Int) -> [CollectionMonth] {
        let yearCounts = counts[year] ?? [:]
        return (1...12).map {
            CollectionMonth(number: $0, count: yearCounts[$0]?.values.reduce(0, +) ?? 0)
        }
    }

    public func weeks(in year: Int) -> [CollectionWeek] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return [] }
        let leading = calendar.component(.weekday, from: first) - 1
        var days = [CollectionDay?](repeating: nil, count: leading)
        let yearCounts = counts[year] ?? [:]
        for month in 1...12 {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let numbers = calendar.range(of: .day, in: .month, for: date) else { continue }
            for day in numbers {
                days.append(CollectionDay(year: year, month: month, day: day,
                                          count: yearCounts[month]?[day] ?? 0))
            }
        }
        let trailing = (7 - days.count % 7) % 7
        days.append(contentsOf: repeatElement(nil, count: trailing))
        return stride(from: 0, to: days.count, by: 7).map { index in
            CollectionWeek(id: index / 7, days: Array(days[index..<(index + 7)]))
        }
    }
}

public struct CollectionWeek: Identifiable, Sendable {
    public let id: Int
    public let days: [CollectionDay?]

    public var startingMonth: Int? {
        days.compactMap { $0 }.first { $0.day == 1 }?.month
    }
}

public struct CollectionDay: Identifiable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let count: Int

    public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public struct CollectionMonth: Identifiable, Sendable {
    public let number: Int
    public let count: Int

    public var id: Int { number }
}
