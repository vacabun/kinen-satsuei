import KinenCore
import SwiftUI

struct JournalList: View {
    let library: AppLibrary
    @State private var editing: LibraryEntry?
    @State private var searchText = ""
    @State private var kindFilter: EntryKind?
    @State private var matchedEntries: [LibraryEntry] = []
    @State private var matchedDrafts: [EntryDraft] = []
    @State private var loadedRequest: SearchRequest?

    private struct SearchRequest: Equatable {
        let revision: Int
        let draftVersion: Int
        let text: String
        let kind: EntryKind?
    }

    var body: some View {
        let query = LibraryQuery(searchText)
        let request = SearchRequest(revision: library.snapshotVersion, draftVersion: library.draftVersion,
                                    text: searchText, kind: kindFilter)
        let needsFiltering = !query.isEmpty || kindFilter != nil
        let searching = needsFiltering && loadedRequest != request
        let drafts = needsFiltering ? (searching ? [] : matchedDrafts) : library.drafts
        let entries = needsFiltering ? (searching ? [] : matchedEntries) : library.snapshot.entries
        List {
            if !library.snapshot.entries.isEmpty || !library.drafts.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            typeFilter(nil, title: "全部")
                            ForEach(EntryKind.allCases) { typeFilter($0, title: $0.title) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if !drafts.isEmpty {
                Section("草稿") {
                    ForEach(drafts) { draft in
                        Button { editing = draft.entry } label: {
                            JournalRow(entry: draft.entry)
                        }
                    }
                }
            }
            if !entries.isEmpty {
                Section("已完成") {
                    ForEach(entries) { entry in
                        NavigationLink {
                            JournalDetail(library: library, id: entry.id)
                        } label: {
                            JournalRow(entry: entry)
                        }
                    }
                }
            }
        }
        .overlay {
            if searching {
                ProgressView().accessibilityLabel("正在筛选笔记")
            } else if query.isEmpty && kindFilter != nil && entries.isEmpty && drafts.isEmpty {
                ContentUnavailableView("这个分类还没有笔记", systemImage: "book").allowsHitTesting(false)
            } else if !query.isEmpty && entries.isEmpty && drafts.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .allowsHitTesting(false)
            } else if library.snapshot.entries.isEmpty && library.drafts.isEmpty {
                ContentUnavailableView("还没有笔记", systemImage: "book",
                                       description: Text("点右上角开始记录。"))
                    .allowsHitTesting(false)
            }
        }
        .kinenListStyle()
        .navigationTitle("笔记")
        .searchable(text: $searchText, prompt: "搜索标题、正文或行程")
        .toolbar {
            Button("新建笔记", systemImage: "square.and.pencil") {
                editing = LibraryEntry(kind: kindFilter ?? .journal)
            }
        }
        .sheet(item: $editing) { JournalEditor(library: library, entry: $0) }
        .task(id: request) {
            guard needsFiltering else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(140)) }
                catch { return }
            }
            let entries = library.snapshot.entries
            let drafts = library.drafts
            let kind = request.kind
            let (filteredEntries, filteredDrafts) = await LibraryWork.run {
                (entries.filter { !Task.isCancelled && (kind == nil || $0.kind == kind) && query.matches($0) },
                 drafts.filter { !Task.isCancelled && (kind == nil || $0.entry.kind == kind) && query.matches($0.entry) })
            }
            guard !Task.isCancelled else { return }
            matchedEntries = filteredEntries
            matchedDrafts = filteredDrafts
            loadedRequest = request
        }
    }

    private func typeFilter(_ kind: EntryKind?, title: String) -> some View {
        Button { kindFilter = kind } label: {
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(kindFilter == kind ? Color.kinenOnInk : Color.kinenInk)
                .background(kindFilter == kind ? Color.kinenInk : Color.kinenPaper, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(kindFilter == kind ? .isSelected : [])
    }
}

struct JournalRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.icon)
                .font(.body.weight(.medium))
                .frame(width: 40, height: 40)
                .background(Color.kinenCanvas, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名笔记" : entry.title)
                    .font(.headline)
                Text("\(entry.kind.title) · \(entry.startDate)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.kinenMuted)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct JournalDetail: View {
    let library: AppLibrary
    let id: UUID
    @State private var editing: LibraryEntry?
    @State private var addingMedia = false
    @State private var choosingExisting = false
    @State private var movingEntry: LibraryEntry?
    @State private var addingStop: StopRequest?
    @State private var quickEditMessage: String?
    @State private var quickEditing = false

    private struct StopRequest: Identifiable {
        let id = UUID()
        let day: String
    }

    var body: some View {
        if let entry = library.snapshot.entriesByID[id] {
            List {
                Section {
                    if !entry.mediaIds.isEmpty {
                        NoteCoverImage(library: library, entry: entry, height: 200)
                            .listRowInsets(EdgeInsets())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.kind.title).font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.kinenCanvas, in: Capsule())
                        Text(entry.title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Label(entry.endDate.map { "\(entry.startDate) 至 \($0)" } ?? entry.startDate,
                              systemImage: "calendar")
                            .foregroundStyle(Color.kinenMuted)
                            .font(.subheadline.monospacedDigit())
                        if let location = entry.location, !location.isEmpty {
                            Label(location, systemImage: "mappin")
                                .font(.subheadline).foregroundStyle(Color.kinenMuted)
                        }
                        if let parent = entry.parentId.flatMap({ library.snapshot.entriesByID[$0] }) {
                            NavigationLink {
                                JournalDetail(library: library, id: parent.id)
                            } label: {
                                Label(parent.title, systemImage: parent.kind.icon)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 10)
                }
                if entry.kind == .trip || entry.kind == .live {
                    contextActions(for: entry)
                }
                if !entry.body.isEmpty || !(entry.noteCards ?? []).isEmpty {
                    Section { NoteCardsReading(library: library, entry: entry, includeItinerary: false) }
                }
                if let quickEditMessage {
                    Section {
                        Text(quickEditMessage).font(.subheadline).foregroundStyle(Color.kinenMuted)
                        if let draft = library.drafts.first(where: { $0.id == entry.id }) {
                            Button("继续编辑草稿", systemImage: "pencil") { editing = draft.entry }
                        }
                    }
                }
                let children = library.snapshot.entries.filter { $0.parentId == id }
                if entry.kind == .trip {
                    TravelTimeline(library: library, trip: entry, children: children,
                                   addStop: { addingStop = StopRequest(day: $0) },
                                   addLive: { startChild(.live, in: entry, day: $0) })
                } else if !children.isEmpty {
                    Section("相关笔记") {
                        ForEach(children) { child in
                            NavigationLink {
                                JournalDetail(library: library, id: child.id)
                            } label: {
                                JournalRow(entry: child)
                            }
                        }
                    }
                }
                if !entry.mediaIds.isEmpty {
                    Section("媒体") {
                        ForEach(entry.mediaIds, id: \.self) { mediaId in
                            if let item = library.snapshot.mediaByID[mediaId] {
                                NavigationLink {
                                    MediaDetail(library: library, item: item, contextEntry: entry)
                                } label: {
                                    MediaRow(library: library, item: item)
                                }
                            } else {
                                Text("媒体不可用")
                            }
                        }
                    }
                }
            }
            .kinenListStyle()
            .navigationTitle(entry.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if entry.kind != .trip && entry.kind != .live {
                    Button("添加媒体", systemImage: "photo.badge.plus") { addingMedia = true }
                }
                Button("编辑") {
                    editing = library.drafts.first { $0.id == entry.id }?.entry ?? entry
                }
                if entry.kind == .live || entry.kind == .memory || entry.parentId != nil {
                    Button("移动到", systemImage: "folder.badge.arrow.forward") {
                        movingEntry = library.drafts.first { $0.id == entry.id }?.entry ?? entry
                    }
                }
            }
            .disabled(quickEditing)
            .sheet(item: $editing) { JournalEditor(library: library, entry: $0) }
            .sheet(item: $movingEntry) { target in
                MoveNoteSheet(library: library, entry: target) { inDraft in
                    quickEditMessage = inDraft ? "归属已更新到草稿，保存笔记后生效。" : "归属已更新。"
                }
            }
            .sheet(item: $addingStop) { request in
                QuickTravelStopEditor(library: library, trip: entry, day: request.day) { draft in
                    quickEditMessage = draft ? "已加入旅行草稿。" : nil
                }
            }
            .sheet(isPresented: $addingMedia) { MediaImportView(library: library, entry: entry) }
            .fullScreenCover(isPresented: $choosingExisting) {
                NoteMediaPicker(library: library, initial: [], linked: Set(entry.mediaIds),
                                confirmationVerb: "关联", suggestedDay: entry.kind == .live ? entry.startDate : nil) { ids in
                    attach(ids, to: entry)
                }
            }
        }
    }

    private func contextActions(for entry: LibraryEntry) -> some View {
        Section {
            if entry.kind == .trip {
                Button("添加行程", systemImage: "mappin") {
                    addingStop = StopRequest(day: suggestedDay(for: entry))
                }
                Button("添加 Live", systemImage: EntryKind.live.icon) {
                    startChild(.live, in: entry, day: suggestedDay(for: entry))
                }
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("写合影回忆", systemImage: EntryKind.memory.icon) {
                        startChild(.memory, in: entry, day: suggestedDay(for: entry))
                    }
                    Button("关联已有媒体", systemImage: "link") { choosingExisting = true }
                    Button("拍摄或导入媒体", systemImage: "photo.badge.plus") { addingMedia = true }
                }
            } else {
                Button("写合影回忆", systemImage: EntryKind.memory.icon) {
                    startChild(.memory, in: entry, day: entry.startDate)
                }
                Menu("添加媒体", systemImage: "photo.badge.plus") {
                    Button("选择当天已有媒体", systemImage: "link") { choosingExisting = true }
                    Button("拍摄或导入媒体", systemImage: "camera") { addingMedia = true }
                }
            }
        }
    }

    private func startChild(_ kind: EntryKind, in parent: LibraryEntry, day: String) {
        editing = LibraryEntry(kind: kind, startDate: day, parentId: parent.id, location: parent.location)
    }

    private func suggestedDay(for trip: LibraryEntry) -> String {
        let today = LocalDay.today()
        return today >= trip.startDate && today <= (trip.endDate ?? trip.startDate) ? today : trip.startDate
    }

    private func attach(_ ids: [UUID], to entry: LibraryEntry) {
        guard !ids.isEmpty else { return }
        quickEditing = true
        quickEditMessage = nil
        Task {
            defer { quickEditing = false }
            do {
                let draft = try await library.store.attachExistingMedia(ids, to: entry.id)
                quickEditMessage = draft ? "已添加到笔记草稿。" : "已关联媒体。"
                await library.reload()
            } catch {
                quickEditMessage = error.localizedDescription
            }
        }
    }

}

private struct MoveNoteSheet: View {
    let library: AppLibrary
    let entry: LibraryEntry
    let onMove: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var queryText = ""
    @State private var moving = false
    @State private var errorMessage: String?

    var body: some View {
        let query = LibraryQuery(queryText)
        let destinations = library.snapshot.entries.filter { candidate in
            candidate.id != entry.id && candidate.kind.allowsChild(entry.kind) &&
                query.matches([candidate.title, candidate.startDate, candidate.location ?? ""])
        }
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        choice(nil, title: "独立笔记", detail: nil)
                    }
                }
                ForEach([EntryKind.trip, .live]) { kind in
                    let matches = destinations.filter { $0.kind == kind }
                    if !matches.isEmpty {
                        Section(kind.title) {
                            ForEach(matches) { parent in
                                let outside = parent.kind == .trip &&
                                    (entry.startDate < parent.startDate || entry.startDate > (parent.endDate ?? parent.startDate))
                                choice(parent.id, title: parent.title,
                                       detail: outside ? "\(parent.startDate) · 笔记日期超出旅行范围" : parent.startDate)
                            }
                        }
                    }
                }
                if destinations.isEmpty {
                    Section {
                        Text(query.isEmpty ? "还没有可以归入的旅行或 Live。" : "没有找到符合条件的归属。")
                            .foregroundStyle(Color.kinenMuted)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(Color.kinenMuted) }
                }
            }
            .kinenListStyle()
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $queryText, prompt: "搜索旅行或 Live")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(moving)
                }
            }
            .disabled(moving)
            .interactiveDismissDisabled(moving)
        }
    }

    private func choice(_ id: UUID?, title: String, detail: String?) -> some View {
        Button {
            move(to: id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Color.kinenMuted) }
                }
                Spacer()
                if id == entry.parentId { Image(systemName: "checkmark") }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(id == entry.parentId)
        .accessibilityAddTraits(id == entry.parentId ? .isSelected : [])
    }

    private func move(to id: UUID?) {
        moving = true
        errorMessage = nil
        Task {
            defer { moving = false }
            do {
                let inDraft = try await library.store.moveEntry(entry.id, to: id)
                await library.reload()
                onMove(inDraft)
                dismiss()
            } catch LibraryError.invalidEntry {
                errorMessage = "无法移动笔记。请检查目标旅行或 Live 是否仍存在。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct QuickTravelStopEditor: View {
    let library: AppLibrary
    let trip: LibraryEntry
    let onSave: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusesTitle: Bool
    @State private var stop: TravelStop
    @State private var showsDetails = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(library: AppLibrary, trip: LibraryEntry, day: String, onSave: @escaping (Bool) -> Void) {
        self.library = library
        self.trip = trip
        self.onSave = onSave
        _stop = State(initialValue: TravelStop(date: day))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("行程名称", text: $stop.title)
                        .focused($focusesTitle)
                        .submitLabel(.done)
                        .onSubmit(save)
                    DatePicker("日期", selection: Binding(
                        get: { LocalDay.date(from: stop.date) ?? .now },
                        set: { stop.date = LocalDay.string(from: $0) }
                    ), displayedComponents: .date)
                }
                Section {
                    DisclosureGroup("时间、地点和备注", isExpanded: $showsDetails) {
                        Toggle("指定时间", isOn: Binding(
                            get: { stop.time != nil },
                            set: { stop.time = $0 ? "12:00" : nil }
                        ))
                        if stop.time != nil {
                            DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                        }
                        TextField("地点", text: $stop.location)
                        TextField("备注", text: $stop.note, axis: .vertical)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(Color.kinenMuted) }
            }
            .kinenListStyle()
            .navigationTitle("添加行程")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave) }
            }
            .task { focusesTitle = true }
            .interactiveDismissDisabled(saving)
        }
    }

    private var canSave: Bool { !saving && !stop.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var time: Binding<Date> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return Binding(get: { stop.time.flatMap(formatter.date(from:)) ?? .now },
                       set: { stop.time = formatter.string(from: $0) })
    }

    private func save() {
        guard canSave else { return }
        var candidate = stop
        candidate.title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            defer { saving = false }
            do {
                let usedDraft = try await library.store.appendTravelStop(candidate, to: trip.id)
                await library.reload()
                onSave(usedDraft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TravelTimeline: View {
    let library: AppLibrary
    let trip: LibraryEntry
    let children: [LibraryEntry]
    let addStop: (String) -> Void
    let addLive: (String) -> Void

    private var dates: [String] {
        Set([trip.startDate] + trip.itinerary.map(\.date) + children.map(\.startDate)).sorted()
    }

    var body: some View {
        ForEach(dates, id: \.self) { date in
            Section {
                if stops(on: date).isEmpty && !children.contains(where: { $0.startDate == date }) {
                    Button("添加这一天的行程", systemImage: "plus") { addStop(date) }
                }
                ForEach(stops(on: date)) { stop in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(stop.title, systemImage: "mappin")
                            .font(.headline)
                        if let time = stop.time { Text(time).monospacedDigit().foregroundStyle(.secondary) }
                        if !stop.location.isEmpty { Text(stop.location).foregroundStyle(.secondary) }
                        if !stop.note.isEmpty { Text(stop.note).font(.subheadline) }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(children.filter { $0.startDate == date }) { child in
                    NavigationLink {
                        JournalDetail(library: library, id: child.id)
                    } label: {
                        JournalRow(entry: child)
                    }
                }
            } header: {
                HStack {
                    if date < trip.startDate || date > (trip.endDate ?? trip.startDate) {
                        Text("\(date) · 待调整")
                    } else {
                        Text(date)
                    }
                    Spacer()
                    Menu("添加到这一天", systemImage: "plus.circle") {
                        Button("添加行程", systemImage: "mappin") { addStop(date) }
                        Button("添加 Live", systemImage: EntryKind.live.icon) { addLive(date) }
                    }
                    .labelStyle(.iconOnly)
                    .textCase(nil)
                }
            }
        }
    }

    private func stops(on date: String) -> [TravelStop] {
        trip.itinerary.enumerated().filter { $0.element.date == date }.sorted {
            ($0.element.time ?? "24:00", $0.offset) < ($1.element.time ?? "24:00", $1.offset)
        }.map(\.element)
    }
}

struct TravelStopFields: View {
    @Binding var stop: TravelStop
    let tripStart: String
    let tripEnd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("行程标题", text: $stop.title).font(.headline)
            DatePicker("日期", selection: Binding(
                get: { LocalDay.date(from: stop.date) ?? .now },
                set: { stop.date = LocalDay.string(from: $0) }
            ), displayedComponents: .date)
            if stop.date < tripStart || stop.date > tripEnd {
                Label("这项行程超出旅行日期", systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("添加时间", isOn: Binding(
                get: { stop.time != nil },
                set: { stop.time = $0 ? "12:00" : nil }
            ))
            if stop.time != nil {
                DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
            }
            TextField("地点（选填）", text: $stop.location)
            TextField("备注（选填）", text: $stop.note, axis: .vertical).lineLimit(1...4)
        }
        .padding(.vertical, 6)
    }

    private var time: Binding<Date> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return Binding(
            get: { stop.time.flatMap(formatter.date(from:)) ?? .now },
            set: { stop.time = formatter.string(from: $0) }
        )
    }
}

struct MarkdownBody: View {
    let library: AppLibrary
    let source: String
    var contextEntry: LibraryEntry? = nil
    @State private var blocks: [NoteMarkdownBlock] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                render(blocks[index])
            }
        }
        .task(id: source) {
            let parsed = await LibraryWork.run { NoteMarkdownBlock.parse(source) }
            if !Task.isCancelled { blocks = parsed }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            let allowed = ["http", "https", "mailto"]
            return allowed.contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    @ViewBuilder private func render(_ block: NoteMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit()
                inline(text)
            }
        case .quote(let quote):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "quote.opening").font(.caption)
                    .accessibilityHidden(true)
                inline(quote)
            }
            .foregroundStyle(.secondary)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(verbatim: code).font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.kinenCanvas, in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider()
        case .media(let id, let label):
            if let item = library.snapshot.mediaByID[id] {
                NavigationLink {
                    MediaDetail(library: library, item: item, contextEntry: contextEntry)
                } label: {
                    if item.kind == .video {
                        Label(label.isEmpty ? "播放视频" : label, systemImage: "play.rectangle")
                    } else {
                        AssetImage(store: library.store, item: item, maxPixels: 1200, icon: "photo",
                                   missingLabel: "附件缺失")
                            .frame(maxWidth: .infinity, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(label.isEmpty ? "查看照片" : label)
                    }
                }
                .buttonStyle(.plain)
            } else {
                missingMedia(label)
            }
        }
    }

    private func missingMedia(_ label: String) -> some View {
        Label(label.isEmpty ? "媒体不可用" : "\(label) · 媒体不可用", systemImage: "photo.badge.exclamationmark")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func inline(_ text: String) -> Text {
        guard text.contains(where: { "*_~`[<&\\".contains($0) }) else { return Text(verbatim: text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let markdown = try? AttributedString(markdown: text, options: options) {
            return Text(markdown)
        }
        return Text(verbatim: text)
    }
}

struct NoteCardsReading: View {
    let library: AppLibrary
    let entry: LibraryEntry
    let includeItinerary: Bool

    var body: some View {
        if let cards = entry.noteCards, entry.cardContentMatchesMarkdown {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(cards) { card in
                    if card.kind == .relatedNote, let id = card.noteID {
                        if let linked = library.snapshot.entriesByID[id] {
                            NavigationLink {
                                JournalDetail(library: library, id: id)
                            } label: { Label(linked.title, systemImage: "link") }
                        } else {
                            Label(card.text, systemImage: "link").foregroundStyle(.secondary)
                        }
                    } else if card.kind == .itinerary {
                        if includeItinerary, let stop = card.stop {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stop.title).font(.headline)
                                Text([stop.date, stop.time, stop.location.isEmpty ? nil : stop.location]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if !stop.note.isEmpty { Text(stop.note) }
                            }
                        }
                    } else if !card.markdown.isEmpty {
                        MarkdownBody(library: library, source: card.markdown, contextEntry: includeItinerary ? nil : entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownBody(library: library, source: entry.body, contextEntry: includeItinerary ? nil : entry)
        }
    }
}
