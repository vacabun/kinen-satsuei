import Foundation

public struct PhotoPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Coordinates use the orientation-corrected image, with (0, 0) at its bottom left.
public struct PhotoQuad: Codable, Equatable, Sendable {
    public let corners: [PhotoPoint]

    public init?(corners: [PhotoPoint]) {
        guard corners.count == 4, corners.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
        // Clockwise convex polygon in image coordinates.
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross < -0.0003 else { return nil }
        }
        self.corners = corners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let points = try container.decode([PhotoPoint].self)
        guard let quad = PhotoQuad(corners: points) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid photo quadrilateral")
        }
        self = quad
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(corners)
    }
}
