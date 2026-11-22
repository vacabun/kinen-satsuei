import KinenCore
import XCTest

final class EntryMergeTests: XCTestCase {
    func testCombinesIndependentFieldsAndBodyLines() throws {
        let original = LibraryEntry(kind: .live, title: "Live", body: "第一首\n第二首\n第三首\n")
        var local = original
        local.title = "大阪 Live"
        local.body = "开场\n第二首\n第三首\n"
        var remote = original
        remote.body = "第一首\n第二首\n安可\n"

        guard case .merged(let candidate) = EntryMerge.merge(base: original, local: local, remote: remote) else {
            return XCTFail("Expected independent edits to merge")
        }
        let merged = try XCTUnwrap(candidate)
        XCTAssertEqual(merged.title, "大阪 Live")
        XCTAssertEqual(merged.body, "开场\n第二首\n安可\n")
    }

    func testConflictRetainsBothBodiesAndBase() {
        let base = LibraryEntry(title: "回忆", body: "原文")
        var local = base
        local.body = "本地"
        var remote = base
        remote.body = "远端"
        guard case .conflict(let conflict) = EntryMerge.merge(base: base, local: local, remote: remote) else {
            return XCTFail("Expected overlapping edits to conflict")
        }
        XCTAssertEqual(conflict.fields, [.body])
        XCTAssertEqual(conflict.base, base)
        XCTAssertEqual(conflict.local, local)
        XCTAssertEqual(conflict.remote, remote)
    }

    func testDeletionConflictsOnlyWhenTheOtherSideChanged() {
        let base = LibraryEntry(title: "笔记")
        var remote = base
        remote.title = "修改后的笔记"
        guard case .merged(let deleted) = EntryMerge.merge(base: base, local: nil, remote: base) else {
            return XCTFail("Expected deletion to propagate")
        }
        XCTAssertNil(deleted)
        guard case .conflict(let conflict) = EntryMerge.merge(base: base, local: nil, remote: remote) else {
            return XCTFail("Expected delete-versus-edit conflict")
        }
        XCTAssertEqual(conflict.fields, [.deletion])
    }

    func testOrphanedLiveEntersConflictPlan() {
        let trip = LibraryEntry(kind: .trip, title: "旅程")
        let live = LibraryEntry(kind: .live, title: "Live", parentId: trip.id)
        let plan = EntryMerge.plan(base: [trip], local: [], remote: [trip, live])
        XCTAssertEqual(plan.conflicts[live.id]?.fields, [.parent])
        XCTAssertTrue(plan.entries.isEmpty)
    }

    func testMarkdownMergeHandlesInsertionAndDeletionBoundaries() {
        XCTAssertEqual(MarkdownMerge.merge(base: "A\nB\nC", local: "A\nC", remote: "A\nX\nB\nC"), "A\nX\nC")
        XCTAssertEqual(MarkdownMerge.merge(base: "A\nB\nC", local: "A\nX\nB\nC", remote: "A\nX\nB\nD"), "A\nX\nB\nD")
        XCTAssertNil(MarkdownMerge.merge(base: "A\nB", local: "A\nX\nB", remote: "A\nY\nB"))
        XCTAssertEqual(MarkdownMerge.merge(base: "A\nB\n", local: "A\nB\nC\n", remote: "D\nB\n"), "D\nB\nC\n")
    }
}
