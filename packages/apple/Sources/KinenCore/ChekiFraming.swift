import Foundation

public enum ChekiFraming: Equatable, Sendable {
    case ready, noOutline, tooSmall, nearEdge, wrongShape, multiple

    public struct Candidate: Sendable {
        public let quad: PhotoQuad
        public let confidence: Double

        public init(quad: PhotoQuad, confidence: Double) {
            self.quad = quad
            self.confidence = confidence
        }
    }

    public static func select(_ candidates: [Candidate], imageAspect: Double) -> (PhotoQuad?, Self) {
        func info(_ candidate: Candidate) -> (bounds: CGRect, framing: Self, score: Double, plausible: Bool) {
            let points = candidate.quad.corners
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                                height: (ys.max() ?? 0) - (ys.min() ?? 0))
            func length(_ a: Int, _ b: Int) -> Double {
                hypot((points[a].x - points[b].x) * imageAspect, points[a].y - points[b].y)
            }
            let width = (length(0, 1) + length(2, 3)) / 2
            let height = (length(1, 2) + length(3, 0)) / 2
            let ratio = min(width, height) / max(width, height)
            let plausible = (0.47...0.89).contains(ratio)
            let area = abs(points.indices.reduce(0.0) {
                let a = points[$1], b = points[($1 + 1) % 4]
                return $0 + a.x * b.y - b.x * a.y
            }) / 2
            let margin = min(bounds.minX, bounds.minY, 1 - bounds.maxX, 1 - bounds.maxY)
            let framing: Self
            if margin < 0.028 { framing = .nearEdge }
            else if area < 0.095 { framing = .tooSmall }
            else if !plausible { framing = .wrongShape }
            else { framing = .ready }
            let score = min(area, 0.55) * 1.4 + candidate.confidence * 0.17
                - hypot(bounds.midX - 0.5, bounds.midY - 0.5) * 0.38
                - abs(ratio - 0.65) * 0.34
            return (bounds, framing, score, plausible)
        }

        let ranked = candidates.map { (candidate: $0, info: info($0)) }
        let eligible = ranked.filter { item in
            guard item.info.framing == .ready else { return false }
            // Prefer an enclosing plausible paper frame over artwork printed inside it.
            return !ranked.contains { outer in
                guard outer.candidate.quad != item.candidate.quad,
                      outer.info.plausible,
                      outer.info.framing == .ready || outer.info.framing == .nearEdge else { return false }
                let inset = min(outer.info.bounds.width, outer.info.bounds.height) * 0.018
                return outer.info.bounds.insetBy(dx: inset, dy: inset).contains(item.info.bounds)
            }
        }.sorted { $0.info.score > $1.info.score }
        if let best = eligible.first {
            if eligible.dropFirst().contains(where: {
                distance($0.candidate.quad, best.candidate.quad) > 0.09 && best.info.score - $0.info.score < 0.11
            }) { return (best.candidate.quad, .multiple) }
            return (best.candidate.quad, .ready)
        }
        guard let best = ranked.max(by: { $0.info.score < $1.info.score }) else { return (nil, .noOutline) }
        let status = best.info.framing == .ready ? .nearEdge : best.info.framing
        return (best.candidate.quad, status)
    }

    public static func distance(_ lhs: PhotoQuad, _ rhs: PhotoQuad) -> Double {
        zip(lhs.corners, rhs.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }
}

public struct ChekiAutoCapture {
    private var anchor: PhotoQuad?
    private var started = 0.0
    private var previous = 0.0

    public init() {}

    public mutating func reset() { anchor = nil }

    public mutating func progress(for quad: PhotoQuad?, at time: TimeInterval) -> Double {
        guard let quad else { reset(); return 0 }
        defer { previous = time }
        if let anchor, time > previous, time - previous <= 0.42,
           ChekiFraming.distance(anchor, quad) <= 0.018 {
            return min((time - started) / 1.05, 1)
        }
        anchor = quad
        started = time
        return 0
    }
}

/// Continuous capture must see the previous photo leave the view before it rearms.
public struct ChekiBatchRearm {
    private var emptySince: TimeInterval?
    private var previousFrame: TimeInterval?
    public private(set) var waiting = false

    public init() {}

    public mutating func didCapture() {
        waiting = true
        emptySince = nil
        previousFrame = nil
    }

    public mutating func observe(isEmpty: Bool, at time: TimeInterval) -> Bool {
        guard waiting else { return true }
        defer { previousFrame = time }
        guard isEmpty else {
            emptySince = nil
            return false
        }
        if let previousFrame, time > previousFrame, time - previousFrame <= 0.42,
           let emptySince, time - emptySince >= 0.26 {
            waiting = false
            return true
        }
        if emptySince == nil || previousFrame.map({ time <= $0 || time - $0 > 0.42 }) == true {
            emptySince = time
        }
        return false
    }
}
