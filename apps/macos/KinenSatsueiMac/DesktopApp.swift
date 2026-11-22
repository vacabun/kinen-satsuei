import AppKit
import KinenCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct KinenSatsueiMacApp: App {
    @State private var library = DesktopLibrary()

    var body: some Scene {
        WindowGroup("記念撮影") {
            DesktopWindow(library: library)
                .frame(minWidth: 800, minHeight: 560)
                .tint(.primary)
                .task { await library.reload() }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") { library.editing = LibraryEntry() }
                    .keyboardShortcut("n")
                    .disabled(library.busy || library.editing != nil)
                Button("导入媒体…") { library.chooseMedia() }
                    .keyboardShortcut("i")
                    .disabled(library.busy || library.editing != nil)
            }
        }
    }
}

@MainActor @Observable
final class DesktopLibrary: GitSettingsLibrary {
    private static let base = URL.applicationSupportDirectory.appending(path: "KinenSatsueiMac")
    private static let activeKey = "KinenDesktopLibrary"
    private(set) var store: LibraryStore
    private(set) var snapshot = LibrarySnapshot()
    private(set) var drafts: [EntryDraft] = []
    private(set) var activeName: String
    private(set) var busy = false
    var editing: LibraryEntry?
    var mediaImport: DesktopImport?
    var notice: String?

    init() {
        let selection = UserDefaults.standard.string(forKey: Self.activeKey)
        let name = selection.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? "default"
        activeName = name
        store = LibraryStore(root: Self.base.appending(path: name))
    }

    func reload() async {
        do {
            snapshot = try await store.load()
            drafts = try await store.drafts()
        } catch {
            notice = error.localizedDescription
        }
    }

    var libraryNames: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Self.base.path)) ?? []
        return ["default"] + items.filter { UUID(uuidString: $0) != nil }.sorted()
    }

    func libraryLabel(_ id: String) -> String {
        if id == "default" { return "默认资料库" }
        return UserDefaults.standard.string(forKey: "DesktopLibraryName." + id) ?? "已恢复的资料库"
    }

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { prepareImport(panel.urls) }
    }

    func prepareImport(_ urls: [URL]) {
        guard !busy, editing == nil, mediaImport == nil else { return }
        let items = urls.compactMap(DesktopImport.Item.init(file:))
        if items.isEmpty { notice = "请选择照片或视频。" }
        else { mediaImport = DesktopImport(items: items) }
    }

    func importMedia(_ request: DesktopImport, imageKind: MediaKind, subject: ChekiSubject?,
                     date: String?) async -> [DesktopImport.Item] {
        busy = true
        defer { busy = false }
        var failed: [DesktopImport.Item] = []
        for item in request.items {
            let access = item.file.startAccessingSecurityScopedResource()
            defer { if access { item.file.stopAccessingSecurityScopedResource() } }
            do {
                try await store.importMedia(from: item.file, filename: item.file.lastPathComponent,
                                            mimeType: item.mimeType, kind: item.isVideo ? .video : imageKind,
                                            captureDate: date, memberIds: [], chekiSubject: subject)
            } catch {
                failed.append(item)
                notice = error.localizedDescription
            }
        }
        await reload()
        return failed
    }

    func addSubject(_ name: String, group: Bool) {
        work {
            if group { _ = try await self.store.addGroup(name: name) }
            else { _ = try await self.store.addMember(name: name) }
            await self.reload()
        }
    }

    func switchLibrary(to name: String) {
        guard name != activeName, libraryNames.contains(name) else { return }
        work { try await self.activate(name) }
    }

    func importBackup(from source: URL, name: String?,
                      remote: (connectionID: String, revision: GitRevision)?) async throws -> (id: UUID, summary: BackupSummary) {
        let id = UUID()
        let key = id.uuidString.lowercased()
        let destination = Self.base.appending(path: key)
        let summary = try await LibraryBackup.restore(from: source, to: destination)
        if let remote {
            do {
                try await LibraryStore(root: destination).bindRestoredLibrary(to: remote.connectionID, revision: remote.revision)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        UserDefaults.standard.set(name ?? source.lastPathComponent, forKey: "DesktopLibraryName." + key)
        return (id, summary)
    }

    func switchLibrary(to id: UUID?) async throws {
        try await activate(id?.uuidString.lowercased() ?? "default")
    }

    func backup(restore: Bool) {
        work {
            guard let folder = self.chooseFolder(restore ? "选择备份资料库" : "选择备份保存位置") else { return }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            if restore {
                let (id, summary) = try await self.importBackup(from: folder, name: nil, remote: nil)
                try await self.switchLibrary(to: id)
                self.notice = "已恢复 \(summary.notes) 篇笔记，\(summary.media) 条媒体记录，缺失附件 \(summary.missingAssets) 项。"
            } else {
                let name = "記念撮影-\(LocalDay.today())-\(UUID().uuidString.prefix(6))"
                _ = try await self.store.exportBackup(to: folder.appending(path: name))
                self.notice = "备份已保存到 \(folder.lastPathComponent) / \(name)。"
            }
        }
    }

    private func activate(_ name: String) async throws {
        let next = LibraryStore(root: Self.base.appending(path: name))
        let loaded = try await next.load()
        let localDrafts = try await next.drafts()
        store = next
        snapshot = loaded
        drafts = localDrafts
        activeName = name
        UserDefaults.standard.set(name, forKey: Self.activeKey)
    }

    private func work(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { notice = error.localizedDescription }
        }
    }

    private func chooseFolder(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct DesktopImport: Identifiable {
    let id = UUID()
    let items: [Item]

    struct Item: Identifiable {
        let file: URL
        let mimeType: String
        let isVideo: Bool
        var id: URL { file }

        init?(file: URL) {
            guard file.isFileURL, let type = UTType(filenameExtension: file.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
            self.file = file
            isVideo = type.conforms(to: .movie)
            mimeType = type.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

extension EntryKind {
    var label: String {
        switch self {
        case .memory: "合影回忆"
        case .live: "Live"
        case .trip: "旅行"
        case .journal: "普通笔记"
        }
    }
}

extension MediaKind {
    var label: String {
        switch self {
        case .cheki: "拍立得"
        case .portrait: "合影"
        case .photo: "照片"
        case .video: "视频"
        }
    }
}
