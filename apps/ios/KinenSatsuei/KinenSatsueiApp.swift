import KinenCore
import SwiftUI

@main
struct KinenSatsueiApp: App {
    @State private var library = AppLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .tint(Color(red: 0.63, green: 0.26, blue: 0.34))
                .task { await library.reload() }
        }
    }
}

@MainActor
@Observable
final class AppLibrary {
    let store = LibraryStore(root: URL.applicationSupportDirectory.appending(path: "KinenLibrary"))
    private(set) var snapshot = LibrarySnapshot()
    var error: String?

    func reload() async {
        do { snapshot = try await store.load() }
        catch { self.error = error.localizedDescription }
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

extension EntryKind {
    var title: String {
        switch self {
        case .memory: "合影回忆"
        case .live: "Live"
        case .trip: "旅行"
        case .journal: "普通手帐"
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
