import KinenCore
import XCTest

final class ChekiFramingTests: XCTestCase {
    func testPrefersOuterPaperAndRejectsClippedOrAmbiguousFraming() {
        let paper = frame(0.20, 0.20, 0.80, 0.80, confidence: 0.77)
        let artwork = frame(0.29, 0.29, 0.71, 0.71, confidence: 0.99)
        let selection = ChekiFraming.select([artwork, paper], imageAspect: 0.67)
        XCTAssertEqual(selection.0, paper.quad)
        XCTAssertEqual(selection.1, .ready)
        let clipped = frame(0.01, 0.20, 0.64, 0.80)
        XCTAssertEqual(ChekiFraming.select([clipped], imageAspect: 0.67).1, .nearEdge)
        XCTAssertEqual(ChekiFraming.select([frame(0.38, 0.38, 0.62, 0.62)], imageAspect: 0.67).1, .tooSmall)
        let left = frame(0.06, 0.32, 0.48, 0.74)
        let right = frame(0.52, 0.32, 0.94, 0.74)
        XCTAssertEqual(ChekiFraming.select([left, right], imageAspect: 0.67).1, .multiple)
    }

    func testStabilityResetsOnMovementMissingFrameAndLongGap() {
        let first = frame(0.20, 0.20, 0.80, 0.80).quad
        let moved = frame(0.24, 0.20, 0.84, 0.80).quad
        var state = ChekiAutoCapture()
        XCTAssertEqual(state.progress(for: first, at: 1), 0)
        XCTAssertGreaterThan(state.progress(for: first, at: 1.2), 0)
        XCTAssertEqual(state.progress(for: moved, at: 1.4), 0)
        XCTAssertEqual(state.progress(for: nil, at: 1.5), 0)
        XCTAssertEqual(state.progress(for: moved, at: 2), 0)
        XCTAssertEqual(state.progress(for: moved, at: 2.6), 0)
        for time in [2.8, 3.0, 3.2, 3.4] {
            XCTAssertLessThan(state.progress(for: moved, at: time), 1)
        }
        XCTAssertEqual(state.progress(for: moved, at: 3.7), 1)
    }

    func testContinuousScanningWaitsUntilPreviousPhotoLeavesTheFrame() {
        var gate = ChekiBatchRearm()
        XCTAssertTrue(gate.observe(isEmpty: false, at: 1))
        gate.didCapture()
        XCTAssertFalse(gate.observe(isEmpty: false, at: 2))
        XCTAssertFalse(gate.observe(isEmpty: true, at: 2.2))
        XCTAssertFalse(gate.observe(isEmpty: false, at: 2.4))
        XCTAssertFalse(gate.observe(isEmpty: true, at: 2.6))
        XCTAssertFalse(gate.observe(isEmpty: true, at: 3.2))
        XCTAssertFalse(gate.observe(isEmpty: true, at: 3.35))
        XCTAssertTrue(gate.observe(isEmpty: true, at: 3.5))
        XCTAssertTrue(gate.observe(isEmpty: false, at: 3.7))
    }

    private func frame(_ left: Double, _ bottom: Double, _ right: Double, _ top: Double,
                       confidence: Double = 0.9) -> ChekiFraming.Candidate {
        let points = [(left, top), (right, top), (right, bottom), (left, bottom)]
        return .init(quad: PhotoQuad(corners: points.map { .init(x: $0.0, y: $0.1) })!, confidence: confidence)
    }
}
