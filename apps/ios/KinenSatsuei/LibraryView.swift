import AVKit
import ImageIO
import KinenCore
import SwiftUI

struct LibraryView: View {
    let library: AppLibrary
    @State private var selection: Page = .home
    @State private var addingMedia = false

    private enum Page: Hashable { case home, journal, add, collection, settings }

    var body: some View {
        TabView(selection: Binding(get: { selection }, set: { page in
            if page == .add { addingMedia = true } else { selection = page }
        })) {
            NavigationStack { home }
                .tabItem { Label("首页", systemImage: "house") }.tag(Page.home)
            NavigationStack { JournalList(library: library) }
                .tabItem { Label("手帐", systemImage: "book") }.tag(Page.journal)
            Color.clear
                .tabItem { Label("添加", systemImage: "plus.circle.fill") }.tag(Page.add)
            NavigationStack { collection }
                .tabItem { Label("收藏", systemImage: "heart") }.tag(Page.collection)
            NavigationStack { MemberSettings(library: library) }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(Page.settings)
        }
        .sheet(isPresented: $addingMedia) { MediaImportView(library: library) }
        .alert("操作失败", isPresented: Binding(
            get: { library.error != nil },
            set: { if !$0 { library.error = nil } }
        )) {
            Button("好") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    private var home: some View {
        List {
            Section("最近手帐") {
                if library.snapshot.entries.isEmpty {
                    Button("写第一篇手帐") { selection = .journal }
                }
                ForEach(library.snapshot.entries.prefix(5)) { entry in
                    NavigationLink {
                        JournalDetail(library: library, id: entry.id)
                    } label: {
                        JournalRow(entry: entry)
                    }
                }
            }
            Section("最近媒体") {
                if library.snapshot.media.isEmpty {
                    Button("添加第一张拍立得") { addingMedia = true }
                }
                ForEach(library.snapshot.media.prefix(12)) { item in
                    mediaLink(item)
                }
            }
            Section("成员收藏") {
                Button("拍立得 · \(library.snapshot.chekiCount()) 张") { selection = .collection }
            }
        }
        .navigationTitle("記念撮影")
    }

    private var collection: some View {
        List {
            Section {
                LabeledContent("拍立得总数", value: "\(library.snapshot.chekiCount()) 张")
                ForEach(library.snapshot.members) { member in
                    NavigationLink {
                        MemberCollection(library: library, member: member)
                    } label: {
                        LabeledContent(member.name, value: "\(library.snapshot.chekiCount(for: member.id)) 张")
                    }
                }
            }
            Section("拍立得") {
                ForEach(library.snapshot.media.filter { $0.kind == .cheki }) { item in
                    mediaLink(item)
                }
            }
        }
        .navigationTitle("收藏")
    }

    private func mediaLink(_ item: LibraryMedia) -> some View {
        NavigationLink {
            MediaDetail(library: library, item: item)
        } label: {
            MediaRow(library: library, item: item)
        }
    }
}

struct MemberCollection: View {
    let library: AppLibrary
    let member: Member

    private var photos: [LibraryMedia] {
        library.snapshot.media.filter { $0.kind == .cheki && $0.memberIds.contains(member.id) }
    }

    private var byMonth: [(key: String, value: Int)] {
        Dictionary(grouping: photos) { $0.captureDate.map { String($0.prefix(7)) } ?? "日期未知" }
            .mapValues(\.count)
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        List {
            Section("按拍摄月统计") {
                ForEach(byMonth, id: \.key) { month in
                    LabeledContent(month.key, value: "\(month.value) 张")
                }
            }
            Section("拍立得 · \(photos.count) 张") {
                ForEach(photos) { item in
                    NavigationLink {
                        MediaDetail(library: library, item: item)
                    } label: {
                        MediaRow(library: library, item: item)
                    }
                }
            }
        }
        .navigationTitle(member.name)
    }
}

struct MemberSettings: View {
    let library: AppLibrary
    @State private var name = ""
    @State private var saving = false

    var body: some View {
        Form {
            Section("成员") {
                ForEach(library.snapshot.members) { member in Text(member.name) }
                TextField("新成员姓名", text: $name)
                Button("添加成员") {
                    let newName = name
                    saving = true
                    Task {
                        if await library.perform({ try await library.store.addMember(name: newName) }) {
                            name = ""
                        }
                        saving = false
                    }
                }
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("设置")
    }
}

struct MediaRow: View {
    let library: AppLibrary
    let item: LibraryMedia

    var body: some View {
        HStack {
            AssetImage(url: library.store.assetURL(item.original), maxPixels: 180,
                       icon: item.kind == .video ? "video" : "photo")
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(item.kind.title)
                Text(item.captureDate ?? "日期未知")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AssetImage: View {
    let url: URL
    let maxPixels: Int
    let icon: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: icon).foregroundStyle(.secondary) }
        }
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: thumbnail)
            }.value
        }
    }
}

struct MediaDetail: View {
    let library: AppLibrary
    let item: LibraryMedia
    @State private var player: AVPlayer?
    @State private var playbackFile: URL?
    @State private var playbackError: String?

    var body: some View {
        List {
            if item.kind == .video {
                if let player { VideoPlayer(player: player).frame(height: 250) }
                else if let playbackError { Text(playbackError) }
                else { ProgressView() }
            } else {
                AssetImage(url: library.store.assetURL(item.original), maxPixels: 1800, icon: "photo")
                    .frame(maxWidth: .infinity)
            }
            LabeledContent("拍摄日期", value: item.captureDate ?? "日期未知")
            let names = library.snapshot.members.filter { item.memberIds.contains($0.id) }.map(\.name)
            if !names.isEmpty { LabeledContent("成员", value: names.joined(separator: "、")) }
            if !item.note.isEmpty { Text(item.note) }
        }
        .navigationTitle(item.kind.title)
        .task {
            guard item.kind == .video, player == nil else { return }
            let source = library.store.assetURL(item.original)
            let fileExtension = URL(fileURLWithPath: item.original.originalFilename).pathExtension
            var target = URL.temporaryDirectory.appending(path: UUID().uuidString)
            if !fileExtension.isEmpty { target.appendPathExtension(fileExtension) }
            do {
                try FileManager.default.linkItem(at: source, to: target)
                playbackFile = target
                player = AVPlayer(url: target)
            } catch {
                playbackError = error.localizedDescription
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let playbackFile { try? FileManager.default.removeItem(at: playbackFile) }
            playbackFile = nil
        }
    }
}
