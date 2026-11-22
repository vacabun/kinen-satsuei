import Foundation
import KinenCore
import XCTest

final class NoteCardTests: XCTestCase {
    func testSuggestedTitleUsesFirstTextAndFallsBackForMediaOnly() {
        let media = NoteCard(kind: .media, media: [.init(id: UUID(), label: "拍立得", video: false)])
        let body = NoteCard(kind: .markdown, text: "\n## 大阪散步\n\n后来去了会场。")
        XCTAssertEqual(NoteCard.suggestedTitle(from: [media, body], fallback: "笔记 · 2026-11-22"), "大阪散步")
        XCTAssertEqual(NoteCard.suggestedTitle(from: [media], fallback: "笔记 · 2026-11-22"), "笔记 · 2026-11-22")
    }

    func testLegacyMarkdownKeepsUnsupportedSyntaxAndFindsUsualCards() {
        let source = "## Live\n\n- 第一首\n- 第二首\n\n```swift\n\nlet a = 2\n```\n\n---"
        let cards = NoteCard.fromMarkdown(source)
        XCTAssertEqual(cards.map(\.kind), [.heading, .bullets, .markdown, .divider])
        XCTAssertEqual(NoteCard.markdown(cards), source)
    }

    func testCardsAndLocksSurviveDraftAndBackup() async throws {
        let root = URL.temporaryDirectory.appending(path: "KinenCards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let backup = root.appending(path: "backup")
        let store = LibraryStore(root: source)
        var note = LibraryEntry(kind: .trip, title: "旅行")
        let stop = TravelStop(date: note.startDate, title: "去会场")
        let cards = [
            NoteCard(kind: .itinerary, locked: true, stop: stop),
            NoteCard(kind: .heading, text: "第一天"),
            NoteCard(kind: .text, text: "记录", locked: true)
        ]
        note.replaceNoteCards(cards)
        try await store.saveDraft(note)
        let drafts = try await store.drafts()
        XCTAssertEqual(drafts.first?.entry.noteCards, cards)
        try await store.publishDraft(note)
        _ = try await LibraryBackup.restore(from: source, to: backup)
        let restored = try await LibraryStore(root: backup).load()
        let saved = try XCTUnwrap(restored.entries.first)
        XCTAssertEqual(saved.noteCards, cards)
        XCTAssertEqual(saved.itinerary, [stop])
        XCTAssertTrue(saved.cardContentMatchesMarkdown)
        XCTAssertEqual(saved.body, "### 去会场\n\n\(note.startDate)\n\n## 第一天\n\n记录")
    }

    func testConcurrentReorderAndContentChangesMergeByCardIdentity() {
        var base = LibraryEntry(title: "笔记")
        var a = NoteCard(kind: .text, text: "原文字")
        let b = NoteCard(kind: .text, text: "另一条")
        base.replaceNoteCards([a, b])
        var local = base
        local.replaceNoteCards([b, a])
        var remote = base
        a.text = "远端文字"
        a.locked = true
        remote.replaceNoteCards([a, b])

        guard case .merged(let result?) = EntryMerge.merge(base: base, local: local, remote: remote) else {
            return XCTFail("Expected merged cards")
        }
        XCTAssertEqual(result.noteCards, [b, a])
        XCTAssertEqual(result.body, "另一条\n\n远端文字")
    }

    func testDeletionVersusEditNeedsResolution() {
        var base = LibraryEntry(title: "笔记")
        var card = NoteCard(kind: .text, text: "原文")
        base.replaceNoteCards([card])
        var local = base
        local.replaceNoteCards([])
        var remote = base
        card.text = "新内容"
        remote.replaceNoteCards([card])
        guard case .conflict(let conflict) = EntryMerge.merge(base: base, local: local, remote: remote) else {
            return XCTFail("Expected unresolved deletion")
        }
        XCTAssertEqual(conflict.fields, [.cards])
        guard case .merged(let result?) = EntryMerge.merge(base: base, local: local, remote: remote, preferring: .remote) else {
            return XCTFail("Expected resolution")
        }
        XCTAssertEqual(result.noteCards, [card])
    }
}
