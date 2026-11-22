#if os(macOS)
import Foundation
import KinenCore
import XCTest

final class SystemGitTransportTests: XCTestCase {
    func testInterruptedPushRecoversAcknowledgedCommitBeforeSendingNewEdits() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)
        let transport = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let store = LibraryStore(root: root.appending(path: "library"))
        var note = LibraryEntry(title: "旅行", body: "基线")
        try await store.save(note)
        let initial = try await LibrarySync(transport: transport).synchronize(store: store, connectionID: "local")
        guard case .applied(let first) = initial else { return XCTFail("Expected initial sync") }

        note.body = "已经送达远端"
        try await store.save(note)
        let interrupted = InterruptedTransport(underlying: transport, afterPush: true)
        do {
            _ = try await LibrarySync(transport: interrupted).synchronize(store: store, connectionID: "local")
            XCTFail("Expected lost response")
        } catch InterruptedTransport.Disconnection.simulated {}
        let stillOld = try await store.syncStatus()
        XCTAssertEqual(stillOld?.revision, first)
        let remoteHead = try await transport.fetch()
        XCTAssertNotEqual(remoteHead, first)

        let reopened = LibraryStore(root: store.root)
        note.body = "中断后继续编辑"
        try await reopened.save(note)
        try await reopened.saveDraft(LibraryEntry(title: "草稿"))
        let result = try await LibrarySync(transport: transport).synchronize(store: reopened, connectionID: "local")
        guard case .applied(let recovered) = result else { return XCTFail("Expected a recovered sync") }
        let stagedRemote = root.appending(path: "remote-during-recovery")
        try await transport.materialize(recovered, to: stagedRemote)
        let entries = try await LibraryStore(root: stagedRemote).load().entries
        XCTAssertEqual(entries.first?.body, note.body)
        let drafts = try await reopened.drafts()
        XCTAssertEqual(drafts.first?.entry.title, "草稿")
    }

    func testInterruptedBeforePushLeavesRemoteUnchangedAndRetriesFreshSnapshot() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)
        let transport = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let store = LibraryStore(root: root.appending(path: "library"))
        try await store.save(LibraryEntry(title: "初稿"))
        let interrupted = InterruptedTransport(underlying: transport, afterPush: false)
        do {
            _ = try await LibrarySync(transport: interrupted).synchronize(store: store, connectionID: "local")
            XCTFail("Expected interruption before push")
        } catch InterruptedTransport.Disconnection.simulated {}
        let emptyHead = try await transport.fetch()
        XCTAssertNil(emptyHead)
        try await store.save(LibraryEntry(title: "重试前新增"))
        let outcome = try await LibrarySync(transport: transport).synchronize(store: store, connectionID: "local")
        guard case .applied(let revision) = outcome else { return XCTFail("Expected resumed push") }
        let finalRemote = root.appending(path: "final")
        try await transport.materialize(revision, to: finalRemote)
        let entries = try await LibraryStore(root: finalRemote).load().entries
        XCTAssertEqual(Set(entries.map(\.title)), ["初稿", "重试前新增"])
    }

    func testMediaScopeKeepsLocalFilesAndSupportsRestoringRemote() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)
        let transport = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let sync = LibrarySync(transport: transport)
        let store = LibraryStore(root: root.appending(path: "library"))
        let photo = root.appending(path: "a.jpg")
        try Data("first".utf8).write(to: photo)
        let first = try await store.importMedia(from: photo, filename: "a.jpg", mimeType: "image/jpeg",
                                                kind: .photo, captureDate: nil, memberIds: [])
        try await store.save(LibraryEntry(title: "回忆", mediaIds: [first.id]))
        let initial = try await sync.synchronize(store: store, connectionID: "test", mediaScope: .metadataOnly)
        guard case .applied = initial else { return XCTFail("Expected metadata sync") }
        let status = try await store.syncStatus()
        XCTAssertEqual(status?.attachments?.notUploaded, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(first.original).path))

        let preview = root.appending(path: "preview")
        let previewRevision = try await sync.downloadRemote(at: preview)
        let restored = LibraryStore(root: preview)
        let summary = try await restored.backupSummary()
        XCTAssertEqual(summary.notes, 1)
        XCTAssertEqual(summary.missingAssets, 1)
        try await restored.bindRestoredLibrary(to: "test", revision: previewRevision)
        let restoredStatus = try await restored.syncStatus()
        XCTAssertEqual(restoredStatus?.revision, previewRevision)

        _ = try await sync.synchronize(store: store, connectionID: "test", mediaScope: .includeAttachments)
        try Data("second".utf8).write(to: photo)
        let second = try await store.importMedia(from: photo, filename: "b.jpg", mimeType: "image/jpeg",
                                                 kind: .photo, captureDate: nil, memberIds: [])
        _ = try await sync.synchronize(store: store, connectionID: "test", mediaScope: .metadataOnly)
        let latest = root.appending(path: "latest")
        _ = try await sync.downloadRemote(at: latest)
        let latestStore = LibraryStore(root: latest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestStore.assetURL(first.original).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latestStore.assetURL(second.original).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetURL(second.original).path))
    }

    func testLiveSyncPreservesDraftsAndEditsMadeWhilePushing() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)
        let transport = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let store = LibraryStore(root: root.appending(path: "library"))
        let original = LibraryEntry(title: "回忆", body: "初稿")
        try await store.save(original)
        let draft = LibraryEntry(title: "本机草稿", body: "草稿内容")
        var edited = original
        edited.body = "推送期间保存的新内容"
        let finalEdit = edited
        let slow = EditingTransport(underlying: transport) {
            try await store.save(finalEdit)
            try await store.saveDraft(draft)
        }
        let result = try await LibrarySync(transport: slow).synchronize(store: store, connectionID: "local/main")
        guard case .applied(let revision) = result else { return XCTFail("Expected local install") }
        let status = try await store.syncStatus()
        XCTAssertEqual(status?.revision, revision)
        let pendingChanges = try await store.hasUnsyncedMetadata()
        XCTAssertEqual(pendingChanges, true)
        let snapshot = try await store.load()
        let drafts = try await store.drafts()
        XCTAssertEqual(snapshot.entries.first?.body, edited.body)
        XCTAssertEqual(drafts.first?.entry.body, draft.body)

        let check = root.appending(path: "remote-before-followup")
        try await transport.materialize(revision, to: check)
        let remoteEntries = try await LibraryStore(root: check).load().entries
        XCTAssertEqual(remoteEntries.first?.body, original.body)
        let next = try await LibrarySync(transport: transport).synchronize(store: store, connectionID: "local/main")
        guard case .applied(let nextRevision) = next else { return XCTFail("Expected pending changes to publish") }
        XCTAssertNotEqual(nextRevision, revision)
        let remainingChanges = try await store.hasUnsyncedMetadata()
        XCTAssertEqual(remainingChanges, false)
        let finalRemote = root.appending(path: "remote-after-followup")
        try await transport.materialize(nextRevision, to: finalRemote)
        let syncedEntries = try await LibraryStore(root: finalRemote).load().entries
        XCTAssertEqual(syncedEntries.first?.body, edited.body)
        do {
            _ = try await LibrarySync(transport: transport).synchronize(store: store, connectionID: "other/main")
            XCTFail("An established anchor must belong to the same connection")
        } catch LibrarySyncError.differentConnection {}
    }

    func testSyncCombinesIndependentChangesAndNeverPushesConflicts() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)
        let a = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let b = try EmbeddedGitTransport(remote: remote, branch: "main", repository: root.appending(path: "b.git"), credentials: nil)
        let syncA = LibrarySync(transport: a)
        let syncB = LibrarySync(transport: b)
        let original = LibraryStore(root: root.appending(path: "local-a"))
        let note = LibraryEntry(title: "回忆", body: "开场\n结束\n")
        try await original.save(note)
        let initial = root.appending(path: "initial")
        _ = try await original.exportBackup(to: initial)
        let cloned = root.appending(path: "local-b")
        let initialResult = try await syncA.synchronize(local: initial, anchor: nil, mergedAt: cloned)
        guard case .ready(_, let anchor) = initialResult else { return XCTFail("Initial sync failed") }
        let second = LibraryStore(root: cloned)

        var ours = note
        ours.title = "大阪回忆"
        try await original.save(ours)
        let outgoingA = root.appending(path: "out-a")
        _ = try await original.exportBackup(to: outgoingA)

        var theirs = note
        theirs.body = "开场\n安可\n"
        try await second.save(theirs)
        let outgoingB = root.appending(path: "out-b")
        _ = try await second.exportBackup(to: outgoingB)
        let firstMerged = root.appending(path: "first-merged")
        _ = try await syncB.synchronize(local: outgoingB, anchor: anchor, mergedAt: firstMerged)

        let merged = root.appending(path: "merged")
        let updated = try await syncA.synchronize(local: outgoingA, anchor: anchor, mergedAt: merged)
        guard case .ready(_, let latest) = updated else { return XCTFail("Expected automatic merge") }
        let mergedStore = LibraryStore(root: merged)
        let mergedEntries = try await mergedStore.load().entries
        let combined = try XCTUnwrap(mergedEntries.first)
        XCTAssertEqual(combined.title, "大阪回忆")
        XCTAssertEqual(combined.body, "开场\n安可\n")

        var collision = note
        collision.body = "开场\n其他内容\n"
        try await second.save(collision)
        let conflicting = root.appending(path: "conflicting")
        _ = try await second.exportBackup(to: conflicting)
        let blocked = root.appending(path: "blocked")
        let result = try await syncB.synchronize(local: conflicting, anchor: anchor, mergedAt: blocked)
        guard case .conflicts(let conflicts) = result else { return XCTFail("Expected conflict") }
        XCTAssertEqual(conflicts.first?.fields, ["body"])
        XCTAssertEqual(conflicts.first?.noteVersions?.local?.body, collision.body)
        XCTAssertEqual(conflicts.first?.noteVersions?.remote?.body, combined.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
        let remoteAfterConflict = try await a.fetch()
        XCTAssertEqual(remoteAfterConflict, latest)

        let oldToken = try XCTUnwrap(conflicts.first?.resolutionToken)
        var advanced = combined
        advanced.body = "开场\n远端再次修改\n"
        try await mergedStore.save(advanced)
        let advancedBackup = root.appending(path: "advanced-backup")
        _ = try await mergedStore.exportBackup(to: advancedBackup)
        _ = try await a.publish(snapshot: advancedBackup, basedOn: latest)
        let review = try await syncB.synchronize(local: conflicting, anchor: anchor, mergedAt: blocked,
                                                  resolutions: [oldToken: .local])
        guard case .conflicts(let changed) = review else { return XCTFail("Expected updated conflict after remote edit") }
        let newToken = try XCTUnwrap(changed.first?.resolutionToken)
        XCTAssertNotEqual(newToken, oldToken)
        XCTAssertEqual(changed.first?.noteVersions?.remote?.body, advanced.body)

        let resolved = try await syncB.synchronize(local: conflicting, anchor: anchor, mergedAt: blocked,
                                                    resolutions: [newToken: .local])
        guard case .ready = resolved else { return XCTFail("Expected successful resolution") }
        let finalEntries = try await LibraryStore(root: blocked).load().entries
        XCTAssertEqual(finalEntries.first?.title, combined.title)
        XCTAssertEqual(finalEntries.first?.body, collision.body)
    }

    func testTwoClientsPublishFetchAndRejectStaleUpdates() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = root.appending(path: "remote.git")
        try createRemote(at: remote)

        let a = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "a.git"))
        let b = try SystemGitTransport(remote: remote, branch: "main", repository: root.appending(path: "b.git"))
        let store = LibraryStore(root: root.appending(path: "library"))
        let draft = LibraryEntry(title: "本地草稿")
        try await store.saveDraft(draft)
        var note = LibraryEntry(title: "旅行回忆", body: "**初稿**")
        try await store.save(note)

        let initialHead = try await a.fetch()
        XCTAssertNil(initialHead)
        let snapshotA = root.appending(path: "snapshot-a")
        _ = try await store.exportBackup(to: snapshotA)
        let first = try await a.publish(snapshot: snapshotA, basedOn: initialHead)
        let observedByB = try await b.fetch()
        XCTAssertEqual(observedByB, first)
        let unchanged = try await b.publish(snapshot: snapshotA, basedOn: first)
        XCTAssertEqual(unchanged, first)

        let restored = root.appending(path: "from-remote")
        try await b.materialize(first, to: restored)
        let incoming = LibraryStore(root: restored)
        let restoredEntries = try await incoming.load().entries
        let restoredDrafts = try await incoming.drafts()
        XCTAssertEqual(restoredEntries.first?.body, "**初稿**")
        XCTAssertTrue(restoredDrafts.isEmpty)

        note.body = "**远端修改**"
        try await store.save(note)
        let snapshotB = root.appending(path: "snapshot-b")
        _ = try await store.exportBackup(to: snapshotB)
        let second = try await b.publish(snapshot: snapshotB, basedOn: first)
        XCTAssertNotEqual(second, first)
        let isDescendant = try await b.isAncestor(first, of: second)
        XCTAssertTrue(isDescendant)
        do {
            _ = try await a.publish(snapshot: snapshotA, basedOn: first)
            XCTFail("A stale client should not overwrite the remote")
        } catch GitTransportError.remoteChanged(let expected, let actual) {
            XCTAssertEqual(expected, first)
            XCTAssertEqual(actual, second)
        }
    }

    private func createRemote(at remote: URL) throws {
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        setup.arguments = ["init", "--bare", "--template=", remote.path]
        setup.standardOutput = FileHandle.nullDevice
        setup.standardError = FileHandle.nullDevice
        try setup.run()
        setup.waitUntilExit()
        XCTAssertEqual(setup.terminationStatus, 0)

    }

}
private struct EditingTransport: GitTransport {
    let underlying: SystemGitTransport
    let onPublish: @Sendable () async throws -> Void

    func fetch() async throws -> GitRevision? { try await underlying.fetch() }
    func materialize(_ revision: GitRevision, to destination: URL) async throws {
        try await underlying.materialize(revision, to: destination)
    }
    func isAncestor(_ ancestor: GitRevision, of revision: GitRevision) async throws -> Bool {
        try await underlying.isAncestor(ancestor, of: revision)
    }
    func publish(snapshot: URL, basedOn expected: GitRevision?) async throws -> GitRevision {
        try await onPublish()
        return try await underlying.publish(snapshot: snapshot, basedOn: expected)
    }
}
private struct InterruptedTransport: JournaledGitTransport {
    enum Disconnection: Error { case simulated }
    let underlying: SystemGitTransport
    let afterPush: Bool

    func fetch() async throws -> GitRevision? { try await underlying.fetch() }
    func materialize(_ revision: GitRevision, to destination: URL) async throws {
        try await underlying.materialize(revision, to: destination)
    }
    func isAncestor(_ ancestor: GitRevision, of revision: GitRevision) async throws -> Bool {
        try await underlying.isAncestor(ancestor, of: revision)
    }
    func publish(snapshot: URL, basedOn expected: GitRevision?) async throws -> GitRevision {
        try await publish(snapshot: snapshot, basedOn: expected, beforePush: { _ in })
    }
    func publish(snapshot: URL, basedOn expected: GitRevision?,
                 beforePush: @escaping @Sendable (GitRevision) throws -> Void) async throws -> GitRevision {
        _ = try await underlying.publish(snapshot: snapshot, basedOn: expected) { revision in
            try beforePush(revision)
            if !afterPush { throw Disconnection.simulated }
        }
        throw Disconnection.simulated
    }
}
#endif
