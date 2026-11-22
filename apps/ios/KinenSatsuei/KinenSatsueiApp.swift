import KinenCore
import SwiftUI

@main
struct KinenSatsueiApp: App {
    @State private var library = AppLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .tint(Color.primary)
                .task { await library.reload() }
        }
    }
}

@MainActor
@Observable
final class AppLibrary: GitSettingsLibrary {
    private static let activeKey = "KinenActiveLibrary"
    private static let namesKey = "KinenRestoredLibraryNames"
    private static let libraryRoot = URL.applicationSupportDirectory
    private static let restoredRoot = libraryRoot.appending(path: "KinenLibraries")
    private(set) var store: LibraryStore
    private(set) var activeLibraryID: UUID?
    private(set) var libraryChoices: [LocalLibraryChoice] = []
    private(set) var snapshotVersion = 0
    private(set) var snapshot = LibrarySnapshot() {
        didSet { snapshotVersion &+= 1 }
    }
    private(set) var draftVersion = 0
    private(set) var drafts: [EntryDraft] = [] {
        didSet { draftVersion &+= 1 }
    }
    var error: String?

    init() {
        let storedID = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        let id = storedID.flatMap { FileManager.default.fileExists(atPath: Self.location(for: $0).path) ? $0 : nil }
        activeLibraryID = id
        store = LibraryStore(root: Self.location(for: id))
        refreshLibraryChoices()
    }

    func importBackup(from source: URL, name: String? = nil,
                      remote: (connectionID: String, revision: GitRevision)? = nil) async throws -> (id: UUID, summary: BackupSummary) {
        let id = UUID()
        let location = Self.location(for: id)
        let summary = try await LibraryBackup.restore(from: source, to: location)
        if let remote {
            do {
                try await LibraryStore(root: location).bindRestoredLibrary(to: remote.connectionID, revision: remote.revision)
            } catch {
                try? FileManager.default.removeItem(at: location)
                throw error
            }
        }
        var names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        names[id.uuidString] = name ?? source.lastPathComponent
        UserDefaults.standard.set(names, forKey: Self.namesKey)
        refreshLibraryChoices()
        return (id, summary)
    }

    func switchLibrary(to id: UUID?) async throws {
        let nextStore = LibraryStore(root: Self.location(for: id))
        let nextSnapshot = try await nextStore.load()
        let nextDrafts = try await nextStore.drafts()
        activeLibraryID = id
        store = nextStore
        snapshot = nextSnapshot
        drafts = nextDrafts
        UserDefaults.standard.set(id?.uuidString, forKey: Self.activeKey)
    }

    private static func location(for id: UUID?) -> URL {
        if let id { return restoredRoot.appending(path: id.uuidString.lowercased()) }
        return libraryRoot.appending(path: "KinenLibrary")
    }

    private func refreshLibraryChoices() {
        let names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        let directories = (try? FileManager.default.contentsOfDirectory(at: Self.restoredRoot,
                                                                        includingPropertiesForKeys: nil)) ?? []
        let restored = directories.compactMap { url -> LocalLibraryChoice? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return LocalLibraryChoice(id: id, name: names[id.uuidString] ?? "已恢复的资料库")
        }.sorted { ($0.name, $0.id?.uuidString ?? "") < ($1.name, $1.id?.uuidString ?? "") }
        libraryChoices = [LocalLibraryChoice(id: nil, name: "默认资料库")] + restored
    }

    private var recentChekiKey: String { "KinenRecentChekiSubjects." + store.root.lastPathComponent }

    func recentChekiSubjects() -> [ChekiSubject] {
        (UserDefaults.standard.stringArray(forKey: recentChekiKey) ?? []).compactMap { item in
            guard let id = UUID(uuidString: String(item.dropFirst())) else { return nil }
            switch item.first {
            case "m": return snapshot.membersByID[id]?.archived == false ? .member(id) : nil
            case "g": return snapshot.groupsByID[id] == nil ? nil : .group(id)
            default: return nil
            }
        }
    }

    func rememberChekiSubject(_ subject: ChekiSubject?) {
        guard let subject else { return }
        let key: String
        switch subject {
        case .member(let id): key = "m" + id.uuidString
        case .group(let id): key = "g" + id.uuidString
        }
        let previous = UserDefaults.standard.stringArray(forKey: recentChekiKey) ?? []
        guard previous.first != key else { return }
        let recent = [key] + previous.filter { $0 != key }
        UserDefaults.standard.set(Array(recent.prefix(4)), forKey: recentChekiKey)
    }

    func reload() async {
        let current = store
        do {
            let loaded = try await current.load()
            guard current === store, !Task.isCancelled else { return }
            snapshot = loaded
            await reloadDrafts()
        }
        catch { if current === store { self.error = error.localizedDescription } }
    }

    func noteCover(for entry: LibraryEntry) async -> LibraryMedia? {
        let ids = [entry.coverMediaId].compactMap { $0 } + entry.mediaIds
        let images = ids.compactMap { snapshot.mediaByID[$0] }.filter { $0.kind != .video }
        let store = store
        return await LibraryWork.run {
            images.first { !Task.isCancelled && FileManager.default.fileExists(atPath: store.displayURL(for: $0).path) }
        }
    }

    func reloadDrafts() async {
        let current = store
        do {
            let loaded = try await current.drafts()
            if current === store && !Task.isCancelled { drafts = loaded }
        } catch {
            if current === store { self.error = error.localizedDescription }
        }
    }

    func perform(_ change: () async throws -> Void) async -> Bool {
        do {
            try await change()
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct LocalLibraryChoice: Identifiable {
    let id: UUID?
    let name: String
}

extension EntryKind {
    var title: String {
        switch self {
        case .memory: "合影回忆"
        case .live: "Live"
        case .trip: "旅行"
        case .journal: "普通笔记"
        }
    }

    var icon: String {
        switch self {
        case .memory: "heart"
        case .live: "music.mic"
        case .trip: "suitcase"
        case .journal: "book"
        }
    }
}

extension MediaKind {
    var title: String {
        switch self {
        case .cheki: "拍立得"
        case .portrait: "合影"
        case .photo: "照片"
        case .video: "视频"
        }
    }
}

extension Color {
    static let kinenCanvas = adaptive(0xF6F5F2, 0x151514)
    static let kinenPaper = adaptive(0xFFFFFF, 0x222221)
    static let kinenInk = adaptive(0x181817, 0xF6F5F2)
    static let kinenMuted = adaptive(0x575652, 0xB9B7B1)
    static let kinenLine = adaptive(0xDCDAD5, 0x41403D)
    static let kinenOnInk = adaptive(0xFFFFFF, 0x181817)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func kinenListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.kinenCanvas)
            .tint(.kinenInk)
    }

    func kinenCard(radius: CGFloat = 20) -> some View {
        background(Color.kinenPaper, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.kinenLine, lineWidth: 1) }
    }

    func kinenPrimaryButton() -> some View {
        font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 14)
            .foregroundStyle(Color.kinenOnInk)
            .background(Color.kinenInk, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LibrarySearchRequest: Equatable, Sendable {
    let revision: Int
    let text: String
}

enum LibraryWork {
    static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
