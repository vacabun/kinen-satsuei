import CoreImage
import Foundation
import KinenCore
import XCTest

final class ChekiCorrectionTests: XCTestCase {
    func testRawAndCorrectedAssetsSurviveBackupAndCanBeEditedIndependently() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let store = LibraryStore(root: root.appending(path: "original-library"))
        let member = try await store.addMember(name: "Rin")
        let original = root.appending(path: "original.jpg")
        let correction = root.appending(path: "corrected.jpg")
        try Data("raw photo".utf8).write(to: original)
        try Data("corrected photo".utf8).write(to: correction)
        let corners = try XCTUnwrap(PhotoQuad(corners: [
            PhotoPoint(x: 0.1, y: 0.9), PhotoPoint(x: 0.85, y: 0.88),
            PhotoPoint(x: 0.9, y: 0.1), PhotoPoint(x: 0.12, y: 0.11)
        ]))
        let item = try await store.importMedia(from: original, filename: "original.jpg", mimeType: "image/jpeg",
                                               kind: .cheki, captureDate: "2026-11-21", memberIds: [],
                                               chekiSubject: .member(member.id), corrected: (correction, corners))
        let correctedAsset = try XCTUnwrap(item.corrected)
        XCTAssertEqual(item.correction, corners)
        XCTAssertEqual(store.displayURL(for: item), store.assetURL(correctedAsset))

        let output = root.appending(path: "backup")
        _ = try await store.exportBackup(to: output)
        let restored = root.appending(path: "restored")
        let summary = try await LibraryBackup.restore(from: output, to: restored)
        XCTAssertEqual(summary.media, 1)
        XCTAssertEqual(summary.missingAssets, 0)
        let reopened = LibraryStore(root: restored)
        let media = try await reopened.load().media
        let saved = try XCTUnwrap(media.first)
        XCTAssertEqual(saved.correction, corners)
        XCTAssertEqual(try Data(contentsOf: reopened.displayURL(for: saved)), Data("corrected photo".utf8))
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(saved.original)), Data("raw photo".utf8))

        try await reopened.setChekiCorrection(id: saved.id, corrected: nil)
        let resetSnapshot = try await reopened.load()
        let reset = try XCTUnwrap(resetSnapshot.media.first)
        XCTAssertEqual(reset.id, item.id)
        XCTAssertNil(reset.corrected)
        XCTAssertNil(reset.correction)
        XCTAssertEqual(reopened.displayURL(for: reset), reopened.assetURL(reset.original))
        XCTAssertEqual(resetSnapshot.chekiCount(), 1)
    }

    func testPerspectiveCorrectionRendersExpectedImageSize() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let corners = try XCTUnwrap(PhotoQuad(corners: [
            PhotoPoint(x: 0.25, y: 0.75), PhotoPoint(x: 0.75, y: 0.75),
            PhotoPoint(x: 0.75, y: 0.25), PhotoPoint(x: 0.25, y: 0.25)
        ]))
        let jpeg = try XCTUnwrap(ChekiImageCorrection.jpeg(image: image, corners: corners,
                                                           context: CIContext(options: [.useSoftwareRenderer: true])))
        let corrected = try XCTUnwrap(CIImage(data: jpeg))
        XCTAssertEqual(corrected.extent.width, 200, accuracy: 1)
        XCTAssertEqual(corrected.extent.height, 150, accuracy: 1)
    }

    func testQuadRejectsCrossedOrOutOfBoundsCorners() {
        let a = PhotoPoint(x: 0.1, y: 0.9)
        let b = PhotoPoint(x: 0.9, y: 0.9)
        let c = PhotoPoint(x: 0.9, y: 0.1)
        let d = PhotoPoint(x: 0.1, y: 0.1)
        XCTAssertNotNil(PhotoQuad(corners: [a, b, c, d]))
        XCTAssertNil(PhotoQuad(corners: [a, c, b, d]))
        XCTAssertNil(PhotoQuad(corners: [a, b, c, PhotoPoint(x: -1, y: 0.1)]))
    }
}
