import Foundation
import KinenCore
import XCTest

final class LibraryFixtureTests: XCTestCase {
    func testPortableFixtureRestoresTripAndPhoto() async throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let fixture = repo.appending(path: "fixtures/library-v1")
        let target = URL.temporaryDirectory.appending(path: "KinenFixture-\(UUID().uuidString)")
        defer { if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) } }
        let preview = try await LibraryBackup.preview(from: fixture)
        XCTAssertFalse(preview.title.isEmpty)
        XCTAssertEqual(preview.summary.notes, 2)
        XCTAssertEqual(preview.summary.media, 1)
        XCTAssertEqual(preview.summary.missingAssets, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let summary = try await LibraryBackup.restore(from: fixture, to: target)
        XCTAssertEqual(summary.notes, 2)
        XCTAssertEqual(summary.media, 1)
        XCTAssertEqual(summary.missingAssets, 0)
        let store = LibraryStore(root: target)
        let snapshot = try await store.load()
        let trip = try XCTUnwrap(snapshot.entries.first { $0.kind == .trip })
        let live = try XCTUnwrap(snapshot.entries.first { $0.kind == .live })
        let item = try XCTUnwrap(snapshot.media.first)
        let member = try XCTUnwrap(snapshot.members.first)
        XCTAssertEqual(snapshot.mediaByID[item.id]?.id, item.id)
        XCTAssertEqual(snapshot.entriesByID[live.id], live)
        XCTAssertEqual(snapshot.chekis(for: .member(member.id)).map(\.id), [item.id])
        XCTAssertEqual(snapshot.chekiCount(), 1)
        XCTAssertEqual(live.parentId, trip.id)
        XCTAssertEqual(live.mediaIds, [item.id])
        XCTAssertEqual(trip.itinerary.first?.time, "18:00")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(item.original).path))
        let legacyMember = try XCTUnwrap(snapshot.members.first)
        XCTAssertNil(legacyMember.avatarJPEG)
        XCTAssertNil(legacyMember.supportColors)
    }

    func testMemberProfileKeepsBothColorSlotsAcrossBackupAndEdit() async throws {
        let workspace = URL.temporaryDirectory.appending(path: "KinenMember-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appending(path: "source")
        let backup = workspace.appending(path: "backup")
        let store = LibraryStore(root: source)
        let avatar = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let colors = MemberSupportColors(first: "ef0099", second: "ef0099")

        let member = try await store.saveMember(id: nil, name: " Rin ", avatarJPEG: avatar, colors: colors)
        _ = try await LibraryBackup.restore(from: source, to: backup)
        let restoredStore = LibraryStore(root: backup)
        let restored = try await restoredStore.load()
        let profile = try XCTUnwrap(restored.members.first)
        XCTAssertEqual(profile.id, member.id)
        XCTAssertEqual(profile.name, "Rin")
        XCTAssertEqual(profile.avatarJPEG, avatar)
        XCTAssertEqual(profile.supportColors?.first, "EF0099")
        XCTAssertEqual(profile.supportColors?.second, "EF0099")

        let edited = try await restoredStore.saveMember(id: profile.id, name: "Rin", avatarJPEG: nil,
                                                        colors: MemberSupportColors(first: nil, second: "FFFFFF"),
                                                        aliases: [" りん ", "りん", ""], archived: true)
        XCTAssertEqual(edited.id, member.id)
        XCTAssertNil(edited.avatarJPEG)
        XCTAssertNil(edited.supportColors?.first)
        XCTAssertEqual(edited.supportColors?.second, "FFFFFF")
        XCTAssertEqual(edited.aliases, ["りん"])
        XCTAssertTrue(edited.archived)
        let unchanged = try await restoredStore.saveMember(id: edited.id, name: edited.name, avatarJPEG: nil,
                                                            colors: edited.supportColors)
        XCTAssertEqual(unchanged.id, edited.id)
        XCTAssertEqual(unchanged.aliases, edited.aliases)
        XCTAssertEqual(unchanged.archived, edited.archived)

        let team = try await restoredStore.addGroup(name: "旧名")
        let renamed = try await restoredStore.saveGroup(id: team.id, name: " 新名 ")
        XCTAssertEqual(renamed.id, team.id)
        XCTAssertEqual(renamed.createdAt.timeIntervalSince1970.rounded(.down), team.createdAt.timeIntervalSince1970.rounded(.down))
        XCTAssertEqual(renamed.name, "新名")
    }

    func testMediaImportedFromNotePersistsAssociationAndCover() async throws {
        let workspace = URL.temporaryDirectory.appending(path: "KinenNoteMedia-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(root: workspace)
        var note = LibraryEntry(kind: .live, title: "Live", location: "大阪")
        try await store.save(note)
        let unrelated = LibraryEntry(title: "另一篇笔记")
        try await store.save(unrelated)
        let unrelatedMetadata = workspace.appending(path: "entries/\(unrelated.id.uuidString.lowercased())/entry.json")
        let unrelatedBytes = try Data(contentsOf: unrelatedMetadata)
        try Data("invalid JSON".utf8).write(to: unrelatedMetadata)
        let source = workspace.appending(path: "sample.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: source)
        let item = try await store.importMedia(from: source, filename: "sample.jpg", mimeType: "image/jpeg",
                                               kind: .photo, captureDate: nil, memberIds: [], attachTo: note.id)
        try unrelatedBytes.write(to: unrelatedMetadata)
        let saved = try await store.load()
        note = try XCTUnwrap(saved.entriesByID[note.id])
        XCTAssertEqual(note.mediaIds, [item.id])
        XCTAssertEqual(saved.entries(linkingMedia: item.id).map(\.id), [note.id])
        XCTAssertEqual(note.location, "大阪")
        note.coverMediaId = item.id
        try await store.save(note)
        let updated = try await store.load()
        XCTAssertEqual(updated.entriesByID[note.id]?.coverMediaId, item.id)
    }

    func testQuickTravelAndMediaEditsKeepDraftSeparate() async throws {
        let root = URL.temporaryDirectory.appending(path: "KinenQuickTrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var trip = LibraryEntry(kind: .trip, title: "大阪旅行", startDate: "2026-11-21")
        trip.replaceNoteCards([NoteCard(kind: .text, text: "出发")])
        try await store.save(trip)
        let stop = TravelStop(date: "2026-11-21", time: "17:00", title: "到会场")
        let usedDraft = try await store.appendTravelStop(stop, to: trip.id)
        XCTAssertFalse(usedDraft)
        _ = try await store.appendTravelStop(stop, to: trip.id)
        var loaded = try await store.load()
        var draft = try XCTUnwrap(loaded.entriesByID[trip.id])
        XCTAssertEqual(draft.itinerary, [stop])
        XCTAssertTrue(draft.cardContentMatchesMarkdown)
        draft.title = "未完成的旅行标题"
        try await store.saveDraft(draft)

        let image = root.appending(path: "sample.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: image)
        let photo = try await store.importMedia(from: image, filename: "sample.jpg", mimeType: "image/jpeg",
                                               kind: .photo, captureDate: stop.date, memberIds: [])
        let attachedToDraft = try await store.attachExistingMedia([photo.id, photo.id], to: trip.id)
        XCTAssertTrue(attachedToDraft)
        loaded = try await store.load()
        XCTAssertEqual(loaded.entriesByID[trip.id]?.title, trip.title)
        XCTAssertEqual(loaded.entriesByID[trip.id]?.mediaIds, [])
        let drafts = try await store.drafts()
        XCTAssertEqual(drafts.first?.entry.mediaIds, [photo.id])
        XCTAssertEqual(drafts.first?.entry.title, draft.title)
    }

    func testMoveNoteValidatesHierarchyAndPreservesDraft() async throws {
        let root = URL.temporaryDirectory.appending(path: "KinenMoveNote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let trip = LibraryEntry(kind: .trip, title: "旅行")
        let live = LibraryEntry(kind: .live, title: "Live")
        var memory = LibraryEntry(kind: .memory, title: "回忆", body: "正文")
        try await store.save(trip)
        try await store.save(live)
        try await store.save(memory)

        let movedDraft = try await store.moveEntry(live.id, to: trip.id)
        XCTAssertFalse(movedDraft)
        do {
            _ = try await store.moveEntry(trip.id, to: live.id)
            XCTFail("An invalid relationship should be rejected")
        } catch LibraryError.invalidEntry {}

        memory.body = "尚未完成的正文"
        try await store.saveDraft(memory)
        let drafted = try await store.moveEntry(memory.id, to: live.id)
        XCTAssertTrue(drafted)
        let published = try await store.load()
        XCTAssertEqual(published.entriesByID[live.id]?.parentId, trip.id)
        XCTAssertNil(published.entriesByID[memory.id]?.parentId)
        let drafts = try await store.drafts()
        XCTAssertEqual(drafts.first?.entry.parentId, live.id)
        XCTAssertEqual(drafts.first?.entry.body, memory.body)
        _ = try await store.moveEntry(live.id, to: nil)
        let independent = try await store.load()
        XCTAssertNil(independent.entriesByID[live.id]?.parentId)
    }

    func testChekiAdjustmentRetainsOriginalAndIsRestoredFromBackup() async throws {
        let workspace = URL.temporaryDirectory.appending(path: "KinenChekiAdjustment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appending(path: "library")
        let store = LibraryStore(root: source)
        let member = try await store.saveMember(id: nil, name: "Rin", avatarJPEG: nil, colors: nil)
        let original = workspace.appending(path: "original.jpg")
        let enhanced = workspace.appending(path: "enhanced.jpg")
        let originalBytes = Data([1, 2, 3])
        let adjustedBytes = Data([4, 5, 6])
        try originalBytes.write(to: original)
        try adjustedBytes.write(to: enhanced)

        var adjustments = ChekiAdjustments(exposure: 0.1, glare: 0.6)
        adjustments.glareExclusions = [.init(x: 0.25, y: 0.75)]
        adjustments.glareInclusions = [.init(x: 0.75, y: 0.25, radius: 0.035)]
        let item = try await store.importMedia(from: original, filename: "original.jpg", mimeType: "image/jpeg",
                                               kind: .cheki, captureDate: "2026-11-22", memberIds: [],
                                               chekiSubject: .member(member.id), enhanced: (enhanced, adjustments))
        XCTAssertNil(item.correction)
        let target = workspace.appending(path: "restored")
        _ = try await LibraryBackup.restore(from: source, to: target)
        let restoredStore = LibraryStore(root: target)
        let snapshot = try await restoredStore.load()
        let restored = try XCTUnwrap(snapshot.mediaByID[item.id])
        XCTAssertEqual(restored.adjustments, adjustments)
        XCTAssertEqual(restored.assets.count, 2)
        XCTAssertEqual(try Data(contentsOf: restoredStore.assetURL(restored.original)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: restoredStore.displayURL(for: restored)), adjustedBytes)
        let adjustedAsset = try XCTUnwrap(restored.enhanced)
        try FileManager.default.removeItem(at: restoredStore.assetURL(adjustedAsset))
        XCTAssertEqual(restoredStore.displayURL(for: restored), restoredStore.assetURL(restored.original))
        let quad = try XCTUnwrap(PhotoQuad(corners: [
            .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 0), .init(x: 0, y: 0)
        ]))
        let corrected = workspace.appending(path: "corrected.jpg")
        try Data([7, 8, 9]).write(to: corrected)
        try await restoredStore.setChekiCorrection(id: item.id, corrected: (corrected, quad))
        let croppedSnapshot = try await restoredStore.load()
        let cropped = try XCTUnwrap(croppedSnapshot.mediaByID[item.id])
        let base = try XCTUnwrap(cropped.corrected)
        try await restoredStore.setChekiAdjustments(id: item.id, baseSHA256: base.sha256,
                                                   enhanced: (enhanced, adjustments))
        let editedSnapshot = try await restoredStore.load()
        let edited = try XCTUnwrap(editedSnapshot.mediaByID[item.id])
        XCTAssertEqual(edited.correction, quad)
        XCTAssertEqual(edited.corrected?.sha256, base.sha256)
        XCTAssertEqual(edited.adjustments, adjustments)
        try await restoredStore.setChekiAdjustments(id: item.id, baseSHA256: base.sha256, enhanced: nil)
        let resetSnapshot = try await restoredStore.load()
        let reset = try XCTUnwrap(resetSnapshot.mediaByID[item.id])
        XCTAssertNil(reset.adjustments)
        XCTAssertNil(reset.enhanced)
        XCTAssertEqual(restoredStore.displayURL(for: reset), restoredStore.assetURL(base))
        XCTAssertEqual(try Data(contentsOf: restoredStore.assetURL(reset.original)), originalBytes)
    }

    func testDeleteMediaProtectsDraftReferencesAndSharedFiles() async throws {
        let workspace = URL.temporaryDirectory.appending(path: "KinenDeleteMedia-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = LibraryStore(root: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appending(path: "photo.jpg")
        try Data([1, 2, 3]).write(to: file)
        let first = try await store.importMedia(from: file, filename: "photo.jpg", mimeType: "image/jpeg",
                                                kind: .photo, captureDate: nil, memberIds: [])
        let second = try await store.importMedia(from: file, filename: "photo.jpg", mimeType: "image/jpeg",
                                                 kind: .photo, captureDate: nil, memberIds: [])
        let draft = LibraryEntry(title: "回忆", mediaIds: [first.id])
        try await store.saveDraft(draft)
        do {
            try await store.deleteMedia(id: first.id)
            XCTFail("Expected to protect the draft's attachment")
        } catch LibraryError.mediaInUse {}
        try await store.discardDraft(draft.id)
        try await store.deleteMedia(id: first.id)
        let remaining = try await store.load()
        XCTAssertEqual(remaining.media.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(second.original).path))
        try await store.deleteMedia(id: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetURL(second.original).path))
    }

    func testOrdinaryMediaMetadataCanBeEditedWithoutReplacingItsAsset() async throws {
        let root = URL.temporaryDirectory.appending(path: "KinenMediaDetails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let member = try await store.addMember(name: "Rin")
        let source = root.appending(path: "sample.jpg")
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try bytes.write(to: source)
        let photo = try await store.importMedia(from: source, filename: "sample.jpg", mimeType: "image/jpeg",
                                                kind: .portrait, captureDate: nil, memberIds: [])

        try await store.updateMediaDetails(id: photo.id, captureDate: "2026-11-22", memberIds: [member.id], note: "演出后")
        var snapshot = try await store.load()
        let updated = try XCTUnwrap(snapshot.mediaByID[photo.id])
        XCTAssertEqual(updated.kind, .portrait)
        XCTAssertEqual(updated.captureDate, "2026-11-22")
        XCTAssertEqual(updated.memberIds, [member.id])
        XCTAssertEqual(updated.note, "演出后")
        XCTAssertEqual(updated.original.sha256, photo.original.sha256)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(updated.original)), bytes)

        try await store.updateMediaDetails(id: photo.id, captureDate: nil, memberIds: [], note: "")
        snapshot = try await store.load()
        XCTAssertNil(snapshot.mediaByID[photo.id]?.captureDate)
        XCTAssertEqual(snapshot.mediaByID[photo.id]?.memberIds, [])
    }
}
