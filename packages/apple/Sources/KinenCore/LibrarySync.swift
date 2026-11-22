import CryptoKit
import Foundation

public enum SyncConflictChoice: String, CaseIterable, Identifiable, Sendable {
    case local, remote

    public var id: Self { self }
}

public struct LibrarySyncConflict: Sendable {
    public let id: UUID
    public let collection: String
    public let fields: [String]
    public var noteVersions: EntryMergeConflict? = nil
    public var baseRecord: Data? = nil
    public var localRecord: Data? = nil
    public var remoteRecord: Data? = nil

    public var resolutionToken: String? {
        let payload: [String]
        if let notes = noteVersions, !notes.structural {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let bytes = try? encoder.encode([notes.base, notes.local, notes.remote]) else { return nil }
            payload = [bytes.base64EncodedString()]
        } else if localRecord != nil || remoteRecord != nil {
            payload = [baseRecord, localRecord, remoteRecord].map { $0?.base64EncodedString() ?? "" }
        } else {
            return nil
        }
        let components = [collection, id.uuidString] + fields.sorted() + payload
        guard let data = try? JSONEncoder().encode(components) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LibrarySyncOutcome: Sendable {
    case ready(snapshot: URL, revision: GitRevision)
    case conflicts([LibrarySyncConflict])
}

public enum SyncMediaScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case metadataOnly, includeAttachments

    public var id: Self { self }
}

public struct SyncAttachmentReport: Codable, Sendable {
    public let notUploaded: Int
    public let tooLarge: Int
}

public struct LibrarySyncStatus: Codable, Sendable {
    public let connectionID: String
    public let revision: GitRevision
    public let syncedAt: Date
    public var attachments: SyncAttachmentReport? = nil
    public var metadataDigest: String? = nil
}

public enum LiveSyncOutcome: Sendable {
    case applied(GitRevision)
    case conflicts([LibrarySyncConflict])
}

public enum LibrarySyncError: Error, LocalizedError {
    case differentLibrary, historyChanged, alreadyRunning, differentConnection, emptyRemote

    public var errorDescription: String? {
        switch self {
        case .emptyRemote: "远程分支还没有可恢复的资料库。"
        case .differentLibrary: "远程资料库与本机资料库不同，请先单独恢复或选择其他远程。"
        case .historyChanged: "远程历史已改变，原同步提交已不在远程分支上。"
        case .differentConnection: "此资料库已绑定到另一个 Git 远程或分支。"
        case .alreadyRunning: "这个资料库正在同步。"
        }
    }
}

public actor LibrarySync {
    private let transport: any GitTransport
    private let files = FileManager.default
    private var running = false
    private var workingOnLiveStore = false
    public static let attachmentLimit: UInt64 = 95 * 1_048_576

    public init(transport: any GitTransport) { self.transport = transport }

    public func synchronize(store: LibraryStore, connectionID: String,
                            mediaScope: SyncMediaScope = .includeAttachments,
                            resolutions: [String: SyncConflictChoice] = [:]) async throws -> LiveSyncOutcome {
        guard !workingOnLiveStore else { throw LibrarySyncError.alreadyRunning }
        workingOnLiveStore = true
        defer { workingOnLiveStore = false }
        try await store.beginSync()
        do {
            let result = try await synchronizeLiveStore(store, connectionID: connectionID, mediaScope: mediaScope,
                                                        resolutions: resolutions)
            await store.endSync()
            return result
        } catch {
            await store.endSync()
            throw error
        }
    }

    private func synchronizeLiveStore(_ store: LibraryStore, connectionID: String,
                                      mediaScope: SyncMediaScope,
                                      resolutions: [String: SyncConflictChoice]) async throws -> LiveSyncOutcome {
        let status = try await store.syncStatus()
        guard status == nil || status?.connectionID == connectionID else { throw LibrarySyncError.differentConnection }

        let journal = PendingPushJournal(storeRoot: store.root)
        if let pending = try journal.read() {
            guard pending.connectionID == connectionID else { throw LibrarySyncError.differentConnection }
            if status?.revision != pending.revision,
               let head = try await transport.fetch(),
               try await transport.isAncestor(pending.revision, of: head) {
                let conflicts = try await applyPending(pending, journal: journal, to: store, resolutions: resolutions)
                if !conflicts.isEmpty { return .conflicts(conflicts) }
            }
        }
        try journal.clear()
        try files.createDirectory(at: journal.folder, withIntermediateDirectories: false)
        defer { if !journal.isRecorded { try? journal.clear() } }

        _ = try await store.exportBackup(to: journal.local)
        let anchor = try await store.syncStatus()?.revision
        let outcome = try await synchronizeSnapshot(local: journal.local, anchor: anchor, mergedAt: journal.accepted,
                                                    mediaScope: mediaScope, resolutions: resolutions,
                                                    journal: journal, connectionID: connectionID)
        switch outcome {
        case .conflicts(let conflicts):
            return .conflicts(conflicts)
        case .ready(_, let revision):
            let pending = PendingPush(connectionID: connectionID, revision: revision, mediaScope: mediaScope)
            let conflicts = try await applyPending(pending, journal: journal, to: store, resolutions: resolutions)
            if !conflicts.isEmpty { return .conflicts(conflicts) }
            try journal.clear()
            return .applied(revision)
        }
    }

    private func applyPending(_ pending: PendingPush, journal: PendingPushJournal, to store: LibraryStore,
                              resolutions: [String: SyncConflictChoice]) async throws -> [LibrarySyncConflict] {
        let prepared = LibraryStore(root: journal.local)
        let currentID = try await store.libraryID()
        let baselineID = try await prepared.libraryID()
        guard currentID == baselineID else { throw LibrarySyncError.differentLibrary }
        let base = try await prepared.load()
        let remote = try await LibraryStore(root: journal.accepted).load()
        let report = try attachmentReport(media: remote.media, local: journal.local, accepted: journal.accepted,
                                          scope: pending.mediaScope)
        return try await store.applySyncedLibrary(base: base, remote: remote, from: journal.accepted,
                                                  revision: pending.revision, connectionID: pending.connectionID,
                                                  report: report, resolutions: resolutions)
    }

    public func downloadRemote(at destination: URL) async throws -> GitRevision {
        guard let revision = try await transport.fetch() else { throw LibrarySyncError.emptyRemote }
        try await transport.materialize(revision, to: destination)
        return revision
    }

    private func attachmentReport(media: [LibraryMedia], local: URL, accepted: URL,
                                  scope: SyncMediaScope) throws -> SyncAttachmentReport {
        var notUploaded = 0
        var tooLarge = 0
        for asset in media.flatMap(\.assets) {
            let relative = try LibraryBackup.assetPath(asset)
            guard files.fileExists(atPath: local.appending(path: relative).path),
                  !files.fileExists(atPath: accepted.appending(path: relative).path) else { continue }
            notUploaded += 1
            if scope == .includeAttachments && asset.byteLength > Self.attachmentLimit { tooLarge += 1 }
        }
        return SyncAttachmentReport(notUploaded: notUploaded, tooLarge: tooLarge)
    }

    // The input must be a consistent LibraryStore backup. The caller owns installation
    // and only records the returned revision after the output has been applied.
    public func synchronize(local: URL, anchor: GitRevision?, mergedAt destination: URL,
                            mediaScope: SyncMediaScope = .includeAttachments,
                            resolutions: [String: SyncConflictChoice] = [:]) async throws -> LibrarySyncOutcome {
        try await synchronizeSnapshot(local: local, anchor: anchor, mergedAt: destination, mediaScope: mediaScope,
                                      resolutions: resolutions, journal: nil, connectionID: nil)
    }

    private func synchronizeSnapshot(local: URL, anchor: GitRevision?, mergedAt destination: URL,
                                     mediaScope: SyncMediaScope, resolutions: [String: SyncConflictChoice],
                                     journal: PendingPushJournal?, connectionID: String?) async throws -> LibrarySyncOutcome {
        guard !running else { throw LibrarySyncError.alreadyRunning }
        running = true
        defer { running = false }

        let head = try await transport.fetch()
        if let anchor {
            guard let head, try await transport.isAncestor(anchor, of: head) else {
                throw LibrarySyncError.historyChanged
            }
        }

        let workspace = URL.temporaryDirectory.appending(path: "KinenSync-\(UUID().uuidString)")
        try files.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: workspace) }
        let staging = workspace.appending(path: "merged")
        if let head {
            let remote = workspace.appending(path: "remote")
            try await transport.materialize(head, to: remote)
            let localStore = LibraryStore(root: local)
            let remoteStore = LibraryStore(root: remote)
            let localID = try await localStore.libraryID()
            let remoteID = try await remoteStore.libraryID()
            guard localID == remoteID else { throw LibrarySyncError.differentLibrary }

            let remoteSnapshot = try await remoteStore.load()
            let base: LibrarySnapshot
            if anchor == head {
                base = remoteSnapshot
            } else if let anchor {
                let folder = workspace.appending(path: "base")
                try await transport.materialize(anchor, to: folder)
                let baseStore = LibraryStore(root: folder)
                let baseID = try await baseStore.libraryID()
                guard baseID == localID else { throw LibrarySyncError.differentLibrary }
                base = try await baseStore.load()
            } else {
                // Relate an existing remote to a locally restored copy of the same library.
                base = LibrarySnapshot()
            }
            let localSnapshot = try await localStore.load()
            let plan = try SnapshotMerge.plan(base: base, local: localSnapshot, remote: remoteSnapshot, resolutions: resolutions)
            if !plan.conflicts.isEmpty { return .conflicts(plan.conflicts) }

            let mergedStore = LibraryStore(root: staging)
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            try files.copyItem(at: local.appending(path: "library.json"), to: staging.appending(path: "library.json"))
            try await mergedStore.writeMergedMetadata(plan.snapshot, sources: [local, remote])
            // Preserve existing remote attachments when the user reduces the upload scope.
            try LibraryBackup.copyReferencedAssets(plan.snapshot.media.flatMap(\.assets), from: [remote], to: staging)
            try copyUploadableAssets(plan.snapshot.media, from: local, to: staging, scope: mediaScope)
        } else {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            try LibraryBackup.copyMetadata(from: local, to: staging)
            let snapshot = try await LibraryStore(root: staging).load()
            try copyUploadableAssets(snapshot.media, from: local, to: staging, scope: mediaScope)
        }

        let revision: GitRevision
        if let journal, let connectionID {
            _ = try await LibraryBackup.restore(from: staging, to: destination)
            if let durableTransport = transport as? any JournaledGitTransport {
                revision = try await durableTransport.publish(snapshot: destination, basedOn: head) { revision in
                    try journal.record(PendingPush(connectionID: connectionID, revision: revision, mediaScope: mediaScope))
                }
            } else {
                revision = try await transport.publish(snapshot: destination, basedOn: head)
                try journal.record(PendingPush(connectionID: connectionID, revision: revision, mediaScope: mediaScope))
            }
        } else {
            let stagedOutput = try LibraryBackup.makeStage(for: destination)
            defer { if files.fileExists(atPath: stagedOutput.path) { try? files.removeItem(at: stagedOutput) } }
            try files.removeItem(at: stagedOutput)
            _ = try await LibraryBackup.restore(from: staging, to: stagedOutput)
            revision = try await transport.publish(snapshot: stagedOutput, basedOn: head)
            try LibraryBackup.install(stagedOutput, at: destination)
        }
        return .ready(snapshot: destination, revision: revision)
    }

    private func copyUploadableAssets(_ media: [LibraryMedia], from local: URL, to destination: URL,
                                      scope: SyncMediaScope) throws {
        if scope == .includeAttachments {
            let eligible = media.flatMap(\.assets).filter { $0.byteLength <= Self.attachmentLimit }
            try LibraryBackup.copyReferencedAssets(eligible, from: [local], to: destination)
        }
    }
}

private struct PendingPush: Codable, Sendable {
    let connectionID: String
    let revision: GitRevision
    let mediaScope: SyncMediaScope
}

private struct PendingPushJournal: Sendable {
    let folder: URL

    init(storeRoot: URL) {
        folder = storeRoot.deletingLastPathComponent().appending(path: ".kinen-sync-" + storeRoot.lastPathComponent)
    }

    var local: URL { folder.appending(path: "local") }
    var accepted: URL { folder.appending(path: "accepted") }
    private var marker: URL { folder.appending(path: "pending.json") }

    var isRecorded: Bool { FileManager.default.fileExists(atPath: marker.path) }

    func read() throws -> PendingPush? {
        guard isRecorded else { return nil }
        return try JSONDecoder().decode(PendingPush.self, from: Data(contentsOf: marker))
    }

    func record(_ pending: PendingPush) throws {
        try JSONEncoder().encode(pending).write(to: marker, options: .atomic)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

enum SnapshotMerge {
    static func plan(base: LibrarySnapshot, local: LibrarySnapshot, remote: LibrarySnapshot,
                     resolutions: [String: SyncConflictChoice] = [:])
        throws -> (snapshot: LibrarySnapshot, conflicts: [LibrarySyncConflict]) {
        func noteConflict(id: UUID, versions: EntryMergeConflict) -> LibrarySyncConflict {
            LibrarySyncConflict(id: id, collection: "entries", fields: versions.fields.map(\.rawValue),
                                noteVersions: versions)
        }
        let entries = EntryMerge.plan(base: base.entries, local: local.entries, remote: remote.entries) { id, conflict in
            noteConflict(id: id, versions: conflict).resolutionToken.flatMap { resolutions[$0] }
        }
        var conflicts = entries.conflicts.map { noteConflict(id: $0.key, versions: $0.value) }
        let members = try records(base.members, local.members, remote.members, in: "members", resolutions: resolutions, conflicts: &conflicts)
        let groups = try records(base.groups, local.groups, remote.groups, in: "groups", resolutions: resolutions, conflicts: &conflicts)
        let media = try records(base.media, local.media, remote.media, in: "media", resolutions: resolutions, conflicts: &conflicts)
        let mediaIDs = Set(media.map(\.id))
        for entry in entries.entries where !Set(entry.mediaIds).isSubset(of: mediaIDs) {
            conflicts.append(LibrarySyncConflict(id: entry.id, collection: "entries", fields: ["media"]))
        }
        let memberIDs = Set(members.map(\.id))
        let groupIDs = Set(groups.map(\.id))
        for item in media where !Set(item.memberIds).isSubset(of: memberIDs) ||
            item.groupId.map({ !groupIDs.contains($0) }) == true {
            conflicts.append(LibrarySyncConflict(id: item.id, collection: "media", fields: ["memberIds", "groupId"]))
        }
        let snapshot = LibrarySnapshot(entries: entries.entries, media: media, members: members, groups: groups)
        return (snapshot, conflicts.sorted { ($0.collection, $0.id.uuidString) < ($1.collection, $1.id.uuidString) })
    }

    private static func records<Record: Codable & Identifiable>(
        _ base: [Record], _ local: [Record], _ remote: [Record], in collection: String,
        resolutions: [String: SyncConflictChoice], conflicts: inout [LibrarySyncConflict]
    ) throws -> [Record] where Record.ID == UUID {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func index(_ records: [Record]) throws -> [UUID: Data] {
            try Dictionary(records.map { ($0.id, try encoder.encode($0)) }, uniquingKeysWith: { first, _ in first })
        }
        let old = try index(base)
        let ours = try index(local)
        let theirs = try index(remote)
        let ids = Set(old.keys).union(ours.keys).union(theirs.keys).sorted { $0.uuidString < $1.uuidString }
        var merged: [Record] = []
        for id in ids {
            let base = old[id]
            let local = ours[id]
            let remote = theirs[id]
            let result: Data?
            if local == remote || remote == base {
                result = local
            } else if local == base {
                result = remote
            } else if let base, let local, let remote {
                var merge = try mergeJSON(base: base, local: local, remote: remote)
                if !merge.fields.isEmpty {
                    let conflict = LibrarySyncConflict(id: id, collection: collection, fields: merge.fields,
                                                       baseRecord: base, localRecord: local, remoteRecord: remote)
                    if let token = conflict.resolutionToken, let choice = resolutions[token] {
                        merge = try mergeJSON(base: base, local: local, remote: remote, preferring: choice)
                    } else {
                        conflicts.append(conflict)
                    }
                }
                result = merge.result
            } else {
                let conflict = LibrarySyncConflict(id: id, collection: collection,
                                                   fields: [base == nil ? "addition" : "deletion"],
                                                   baseRecord: base, localRecord: local, remoteRecord: remote)
                if let token = conflict.resolutionToken, let choice = resolutions[token] {
                    result = choice == .local ? local : remote
                } else {
                    conflicts.append(conflict)
                    result = nil
                }
            }
            if let result { merged.append(try decoder.decode(Record.self, from: result)) }
        }
        return merged
    }

    private static func mergeJSON(base: Data, local: Data, remote: Data, preferring choice: SyncConflictChoice? = nil)
        throws -> (result: Data?, fields: [String]) {
        func fields(_ bytes: Data) throws -> [String: NSObject] {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: NSObject] else {
                throw LibraryBackupError.invalidLayout
            }
            return object
        }
        let base = try fields(base)
        let local = try fields(local)
        let remote = try fields(remote)
        var merged: [String: NSObject] = [:]
        var conflicts: [String] = []
        for key in Set(base.keys).union(local.keys).union(remote.keys).sorted() {
            if local[key] == remote[key] || remote[key] == base[key] {
                merged[key] = local[key]
            } else if local[key] == base[key] {
                merged[key] = remote[key]
            } else if key == "updatedAt", let left = local[key] as? String, let right = remote[key] as? String {
                merged[key] = max(left, right) as NSString
            } else if let choice {
                merged[key] = choice == .local ? local[key] : remote[key]
            } else {
                conflicts.append(key)
            }
        }
        return (conflicts.isEmpty ? try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) : nil, conflicts)
    }
}
