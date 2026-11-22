import AVKit
import Charts
import KinenCore
import SwiftUI

struct DesktopWindow: View {
    let library: DesktopLibrary
    @State private var page: Page? = .notes
    @State private var selectedNote: UUID?
    @State private var selectedMedia: UUID?
    @State private var searchText = ""
    @State private var subject: ChekiSubject?
    @State private var dateBasis = CollectionDateBasis.capture

    private enum Page: String, CaseIterable, Identifiable {
        case notes = "笔记", photos = "媒体", collection = "收藏", settings = "设置"
        var id: Self { self }
        var icon: String {
            switch self {
            case .notes: "book"
            case .photos: "photo.on.rectangle"
            case .collection: "heart"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationTitle("記念撮影")
            .navigationSplitViewColumnWidth(min: 140, ideal: 175)
        } content: {
            switch page {
            case .notes: noteList
            case .photos, .collection: mediaList
            case .settings: DesktopSettings(library: library)
            case nil: ContentUnavailableView("请选择一个栏目", systemImage: "sidebar.left")
            }
        } detail: {
            switch page {
            case .notes:
                if let note = library.snapshot.entries.first(where: { $0.id == selectedNote }) {
                    noteDetail(note)
                } else {
                    ContentUnavailableView("选择一篇笔记", systemImage: "book")
                }
            case .photos, .collection:
                if let item = library.snapshot.media.first(where: { $0.id == selectedMedia }) {
                    DesktopMediaDetail(library: library, item: item).id(item.id)
                } else {
                    ContentUnavailableView("选择一项媒体", systemImage: "photo")
                }
            case .settings:
                ContentUnavailableView("资料库与成员", systemImage: "externaldrive")
            case nil:
                Color.clear
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新建笔记", systemImage: "square.and.pencil") { library.editing = LibraryEntry() }
                Button("导入媒体", systemImage: "tray.and.arrow.down") { library.chooseMedia() }
                if library.busy { ProgressView().controlSize(.small) }
            }
        }
        .onChange(of: page) { _, _ in searchText = "" }
        .onChange(of: library.activeName) { _, _ in
            selectedNote = nil
            selectedMedia = nil
            subject = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.contains(where: \.isFileURL) else { return false }
            library.prepareImport(urls)
            return true
        }
        .sheet(item: Binding(get: { library.editing }, set: { library.editing = $0 })) { entry in
            DesktopNoteEditor(library: library, entry: entry)
        }
        .sheet(item: Binding(get: { library.mediaImport }, set: { library.mediaImport = $0 })) { request in
            DesktopImportView(library: library, request: request)
        }
        .alert("記念撮影", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("好") { library.notice = nil }
        } message: {
            Text(library.notice ?? "")
        }
    }

    private var noteList: some View {
        let query = LibraryQuery(searchText)
        let drafts = library.drafts.filter { query.matches($0.entry) }
        let notes = library.snapshot.entries.filter { query.matches($0) }
        return List(selection: $selectedNote) {
            if !drafts.isEmpty {
                Section("草稿") {
                    ForEach(drafts) { draft in
                        Button { library.editing = draft.entry } label: {
                            VStack(alignment: .leading) {
                                Text(draft.entry.title.isEmpty ? "未命名笔记" : draft.entry.title)
                                Text(draft.entry.kind.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("笔记") {
                ForEach(notes) { note in
                    VStack(alignment: .leading) {
                        Text(note.title)
                        Text("\(note.kind.label) · \(note.startDate)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(note.id)
                }
            }
        }
        .overlay {
            if drafts.isEmpty && notes.isEmpty {
                if query.isEmpty { ContentUnavailableView("还没有笔记", systemImage: "book") }
                else { ContentUnavailableView.search(text: searchText) }
            }
        }
        .navigationTitle("笔记")
        .searchable(text: $searchText, prompt: "搜索笔记")
        .navigationSplitViewColumnWidth(min: 245, ideal: 300)
    }

    private var mediaList: some View {
        let search = MediaSearch(snapshot: library.snapshot)
        let query = LibraryQuery(searchText)
        let all = page == .collection ? (subject.map(library.snapshot.chekis(for:)) ??
            library.snapshot.media.filter { $0.kind == .cheki }) : library.snapshot.media
        let items = all.filter { search.matches($0, query: query) }
        return List(selection: $selectedMedia) {
            if page == .collection {
                Section("收藏趋势") {
                    Picker("成员或团体", selection: $subject) {
                        Text("全部拍立得").tag(nil as ChekiSubject?)
                        ForEach(library.snapshot.members) { member in Text(member.name).tag(Optional(ChekiSubject.member(member.id))) }
                        ForEach(library.snapshot.groups) { group in Text(group.name).tag(Optional(ChekiSubject.group(group.id))) }
                    }
                    Picker("统计依据", selection: $dateBasis) {
                        Text("拍摄日期").tag(CollectionDateBasis.capture)
                        Text("入库日期").tag(CollectionDateBasis.added)
                    }
                    let trend = dateBasis.trend(for: all)
                    if let year = trend.years.first {
                        Text("\(String(year)) 年 · \(all.count) 张").font(.caption)
                        Chart(trend.months(in: year)) { month in
                            BarMark(x: .value("月份", month.number), y: .value("张数", month.count))
                        }
                        .chartXAxis { AxisMarks(values: [1, 4, 7, 10, 12]) }
                        .frame(height: 110)
                    } else {
                        Text("暂无可统计的日期").foregroundStyle(.secondary)
                    }
                }
            }
            Section(page == .collection ? "拍立得" : "媒体") {
                ForEach(items) { item in
                    VStack(alignment: .leading) {
                        let names = search.names(for: item)
                        Text(names.isEmpty ? item.kind.label : names.joined(separator: "、"))
                        Text(item.captureDate ?? "日期未知").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                if items.isEmpty { Text("暂无媒体").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(page == .collection ? "收藏" : "媒体")
        .searchable(text: $searchText, prompt: "搜索成员、团体、日期或备注")
        .navigationSplitViewColumnWidth(min: 245, ideal: 300)
    }

    private func noteDetail(_ note: LibraryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(note.title).font(.largeTitle.bold())
                Text("\(note.kind.label) · \(note.startDate)").foregroundStyle(.secondary)
                DesktopMarkdown(source: note.body)
                let children = library.snapshot.entries.filter { $0.parentId == note.id }
                ForEach(note.itinerary.sorted { ($0.date, $0.time ?? "24:00") < ($1.date, $1.time ?? "24:00") }) { stop in
                    VStack(alignment: .leading) {
                        Text(stop.title).font(.headline)
                        Text([stop.date, stop.time, stop.location].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: " · "))
                        if !stop.note.isEmpty { Text(stop.note) }
                    }
                }
                ForEach(children) { child in
                    Button(child.title) { selectedNote = child.id }.buttonStyle(.link)
                }
                ForEach(note.mediaIds, id: \.self) { id in
                    if let item = library.snapshot.media.first(where: { $0.id == id }) {
                        Button("\(item.kind.label) · \(item.captureDate ?? "日期未知")") {
                            selectedMedia = id
                            page = .photos
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
        }
        .toolbar {
            Button("编辑", systemImage: "pencil") {
                library.editing = library.drafts.first { $0.id == note.id }?.entry ?? note
            }
        }
    }
}

private struct DesktopMediaDetail: View {
    let library: DesktopLibrary
    let item: LibraryMedia
    @State private var player: AVPlayer?
    @State private var linkedVideo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let location = library.store.displayURL(for: item)
            if item.kind == .video {
                if let player { VideoPlayer(player: player) }
                else { ContentUnavailableView("视频不可用", systemImage: "video.slash") }
            } else if let image = NSImage(contentsOf: location) {
                GeometryReader { proxy in
                    let turns = item.quarterTurns ?? 0
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: turns % 2 == 0 ? proxy.size.width : proxy.size.height,
                               height: turns % 2 == 0 ? proxy.size.height : proxy.size.width)
                        .rotationEffect(.degrees(Double(turns * 90)))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                ContentUnavailableView("照片不可用", systemImage: "photo")
            }
            let names = MediaSearch(snapshot: library.snapshot).names(for: item)
            Text(([item.kind.label, item.captureDate ?? "日期未知"] + names).joined(separator: " · "))
                .font(.headline)
            if !item.note.isEmpty { Text(item.note).textSelection(.enabled) }
        }
        .padding(24)
        .task {
            guard item.kind == .video else { return }
            let source = library.store.assetURL(item.original)
            let ext = URL(fileURLWithPath: item.original.originalFilename).pathExtension
            let target = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
            if (try? FileManager.default.linkItem(at: source, to: target)) != nil {
                linkedVideo = target
                player = AVPlayer(url: target)
            }
        }
        .onDisappear {
            player?.pause()
            if let linkedVideo { try? FileManager.default.removeItem(at: linkedVideo) }
        }
    }
}
