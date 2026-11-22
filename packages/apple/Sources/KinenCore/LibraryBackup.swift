import CryptoKit
import Foundation

public struct BackupSummary: Sendable {
    public let notes: Int
    public let media: Int
    public let missingAssets: Int
}

public enum LibraryBackupError: Error, LocalizedError {
    case invalidLayout, invalidAsset, destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalidLayout: "该文件夹不是有效的「記念撮影」资料库备份。"
        case .invalidAsset: "备份中的媒体损坏或与资料记录不一致。"
        case .destinationExists: "目标位置已有同名资料库，请选择其他位置。"
        }
    }
}

extension LibraryStore {
    public func backupSummary() throws -> BackupSummary {
        let snapshot = try load()
        let missing = snapshot.media.flatMap(\.assets).count { !FileManager.default.fileExists(atPath: assetURL($0).path) }
        return BackupSummary(notes: snapshot.entries.count, media: snapshot.media.count, missingAssets: missing)
    }

    public func exportBackup(to destination: URL) throws -> BackupSummary {
        let snapshot = try load()
        let stage = try LibraryBackup.makeStage(for: destination)
        defer { try? FileManager.default.removeItem(at: stage) }
        try LibraryBackup.copyMetadata(from: root, to: stage)
        var missing = 0
        var copied: Set<URL> = []
        for asset in snapshot.media.flatMap(\.assets) {
            try Task.checkCancellation()
            let relative = try LibraryBackup.assetPath(asset)
            let source = root.appending(path: relative)
            guard FileManager.default.fileExists(atPath: source.path) else {
                missing += 1
                continue
            }
            if copied.insert(source).inserted {
                let target = stage.appending(path: relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try LibraryBackup.copyRegularFile(from: source, to: target, exactBytes: asset.byteLength)
                try LibraryBackup.verifyAsset(asset, at: target)
            }
        }
        try LibraryBackup.install(stage, at: destination)
        return BackupSummary(notes: snapshot.entries.count, media: snapshot.media.count, missingAssets: missing)
    }
}

public enum LibraryBackup {
    private static let files = FileManager.default
    private static let metadataDirectories = ["entries", "members", "groups", "media"]
    private static let maximumMetadataBytes = 16 * 1024 * 1024
    private static let maximumFiles = 200_000

    public static func preview(from source: URL) async throws -> (title: String, summary: BackupSummary) {
        let destination = URL.temporaryDirectory.appending(path: "kinen-preview-\(UUID().uuidString)")
        let stage = try makeStage(for: destination)
        defer { try? files.removeItem(at: stage) }
        try copyMetadata(from: source, to: stage)
        let store = LibraryStore(root: stage)
        let snapshot = try await store.load()
        try verifyRecordNames(snapshot, at: stage)
        var missing = 0
        var checked: [String: MediaAsset] = [:]
        for asset in snapshot.media.flatMap(\.assets) {
            try Task.checkCancellation()
            let relative = try assetPath(asset)
            if let previous = checked[relative] {
                guard previous.sha256 == asset.sha256, previous.byteLength == asset.byteLength else {
                    throw LibraryBackupError.invalidAsset
                }
                continue
            }
            checked[relative] = asset
            if try existingAsset(in: source, relative: relative) == nil { missing += 1 }
        }
        let title = try await store.libraryTitle()
        return (title, BackupSummary(notes: snapshot.entries.count, media: snapshot.media.count, missingAssets: missing))
    }

    public static func restore(from source: URL, to destination: URL) async throws -> BackupSummary {
        let stage = try makeStage(for: destination)
        defer { try? files.removeItem(at: stage) }
        try copyMetadata(from: source, to: stage)
        let store = LibraryStore(root: stage)
        let snapshot = try await store.load()
        try verifyRecordNames(snapshot, at: stage)

        var missing = 0
        var checked: [String: MediaAsset] = [:]
        for asset in snapshot.media.flatMap(\.assets) {
            try Task.checkCancellation()
            let relative = try assetPath(asset)
            if let previous = checked[relative] {
                guard previous.sha256 == asset.sha256, previous.byteLength == asset.byteLength else {
                    throw LibraryBackupError.invalidAsset
                }
                continue
            }

            checked[relative] = asset
            guard let sourceFile = try existingAsset(in: source, relative: relative) else {
                missing += 1
                continue
            }
            let target = stage.appending(path: relative)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyRegularFile(from: sourceFile, to: target, exactBytes: asset.byteLength)
            try verifyAsset(asset, at: target)
        }
        try Task.checkCancellation()
        try install(stage, at: destination)
        return BackupSummary(notes: snapshot.entries.count, media: snapshot.media.count, missingAssets: missing)
    }

    private static func existingAsset(in root: URL, relative: String) throws -> URL? {
        let parts = relative.split(separator: "/")
        guard let filename = parts.last else { throw LibraryBackupError.invalidLayout }
        var file = root
        for part in parts.dropLast() {
            file.append(path: String(part))
            guard try isDirectoryIfPresent(file) else { return nil }
        }
        file.append(path: String(filename))
        guard try pathExists(file) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LibraryBackupError.invalidLayout
        }
        return file
    }

    static func copyReferencedAssets(_ assets: [MediaAsset], from roots: [URL], to destination: URL) throws {
        var copied: [String: MediaAsset] = [:]
        for asset in assets {
            try Task.checkCancellation()
            let relative = try assetPath(asset)
            if let previous = copied[relative] {
                guard previous.sha256 == asset.sha256, previous.byteLength == asset.byteLength else {
                    throw LibraryBackupError.invalidAsset
                }
                continue
            }
            let target = destination.appending(path: relative)
            if files.fileExists(atPath: target.path) {
                try verifyAsset(asset, at: target)
                copied[relative] = asset
                continue
            }
            for root in roots {
                let source = root.appending(path: relative)
                guard files.fileExists(atPath: source.path) else { continue }
                try verifyAsset(asset, at: source)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyRegularFile(from: source, to: target, exactBytes: asset.byteLength)
                copied[relative] = asset
                break
            }
        }
    }

    static func makeStage(for destination: URL) throws -> URL {
        guard try !pathExists(destination) else { throw LibraryBackupError.destinationExists }
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appending(path: ".kinen-staging-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        return stage
    }

    static func install(_ stage: URL, at destination: URL) throws {
        guard try !pathExists(destination) else { throw LibraryBackupError.destinationExists }
        try files.moveItem(at: stage, to: destination)
    }

    static func copyMetadata(from source: URL, to destination: URL) throws {
        guard try isDirectoryIfPresent(source) else { throw LibraryBackupError.invalidLayout }
        let manifest = source.appending(path: "library.json")
        try copyRegularFile(from: manifest, to: destination.appending(path: "library.json"),
                            maxBytes: maximumMetadataBytes)

        var count = 1
        for name in metadataDirectories {
            let input = source.appending(path: name)
            if try !isDirectoryIfPresent(input) { continue }
            let output = destination.appending(path: name)
            try files.createDirectory(at: output, withIntermediateDirectories: false)
            let children = try files.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            for child in children where child.lastPathComponent != ".DS_Store" {
                try Task.checkCancellation()
                count += name == "entries" ? 2 : 1
                guard count <= maximumFiles else { throw LibraryBackupError.invalidLayout }
                if name == "entries" {
                    guard UUID(uuidString: child.lastPathComponent) != nil, try isDirectoryIfPresent(child) else {
                        throw LibraryBackupError.invalidLayout
                    }
                    let target = output.appending(path: child.lastPathComponent)
                    try files.createDirectory(at: target, withIntermediateDirectories: false)
                    for filename in ["entry.json", "body.md"] {
                        try copyRegularFile(from: child.appending(path: filename), to: target.appending(path: filename),
                                            maxBytes: maximumMetadataBytes)
                    }
                } else {
                    guard child.pathExtension == "json", UUID(uuidString: child.deletingPathExtension().lastPathComponent) != nil else {
                        throw LibraryBackupError.invalidLayout
                    }
                    try copyRegularFile(from: child, to: output.appending(path: child.lastPathComponent),
                                        maxBytes: maximumMetadataBytes)
                }
            }
        }
    }

    static func assetPath(_ asset: MediaAsset) throws -> String {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard asset.sha256.count == 64, asset.sha256.unicodeScalars.allSatisfy(hex.contains),
              asset.byteLength > 0 else { throw LibraryBackupError.invalidAsset }
        if let filename = asset.storedFilename {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz-_.")
            guard !filename.isEmpty, filename.count <= 255, !filename.hasPrefix("."),
                  filename.unicodeScalars.allSatisfy(allowed.contains) else {
                throw LibraryBackupError.invalidAsset
            }
            return "assets/cheki/\(filename)"
        }
        return "assets/sha256/\(asset.sha256.prefix(2))/\(asset.sha256)"
    }

    fileprivate static func copyRegularFile(from source: URL, to destination: URL,
                                             maxBytes: Int? = nil, exactBytes: UInt64? = nil) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, maxBytes.map({ size <= $0 }) ?? true else {
            throw LibraryBackupError.invalidLayout
        }
        if let exactBytes, UInt64(size) != exactBytes { throw LibraryBackupError.invalidAsset }
        try files.copyItem(at: source, to: destination)
        let copied = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard copied.isRegularFile == true, copied.isSymbolicLink != true else {
            throw LibraryBackupError.invalidLayout
        }
    }

    private static func pathExists(_ url: URL) throws -> Bool {
        do {
            _ = try files.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return false
        }
    }

    private static func isDirectoryIfPresent(_ url: URL) throws -> Bool {
        guard try pathExists(url) else { return false }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LibraryBackupError.invalidLayout
        }
        return true
    }

    fileprivate static func verifyAsset(_ asset: MediaAsset, at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: UInt64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            size += UInt64(bytes.count)
            guard size <= asset.byteLength else { throw LibraryBackupError.invalidAsset }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == asset.byteLength, actual == asset.sha256 else { throw LibraryBackupError.invalidAsset }
    }

    private static func verifyRecordNames(_ snapshot: LibrarySnapshot, at root: URL) throws {
        for (directory, ids) in [
            ("entries", snapshot.entries.map(\.id)),
            ("members", snapshot.members.map(\.id)),
            ("groups", snapshot.groups.map(\.id)),
            ("media", snapshot.media.map(\.id))
        ] {
            let expected = Set(ids.map { $0.uuidString.lowercased() + (directory == "entries" ? "" : ".json") })
            let actual = try files.contentsOfDirectory(atPath: root.appending(path: directory).path)
            guard expected.count == ids.count, expected == Set(actual) else { throw LibraryBackupError.invalidLayout }
        }
    }
}
