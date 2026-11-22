import KinenCore
import SwiftUI
import UniformTypeIdentifiers

struct JournalEditor: View {
    let library: AppLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedCard: UUID?
    @State private var entry: LibraryEntry
    @State private var persistedEntry: LibraryEntry
    @State private var cards: [NoteCard]
    @State private var selected: UUID?
    @State private var dragging: UUID?
    @State private var dropTarget: UUID?
    @State private var panel: Panel?
    @State private var picker: MediaDestination?
    @State private var deferredPicker: MediaDestination?
    @State private var preview = false
    @State private var previewFocus: UUID?
    @State private var startingWithText: Bool
    @State private var sorting = false
    @State private var focusAfterInsertion: UUID?
    @State private var saving = false
    @State private var closing = false
    @State private var autosave: Task<Void, Never>?
    @State private var textProjection: Task<Void, Never>?
    @State private var hasPendingText = false
    @State private var savedDraftInSession = false
    @State private var errorMessage: String?
    @State private var confirmingDiscard = false
    @State private var pendingDeletion: NoteCard?
    @State private var undo: UndoAction?
    @State private var externalChange: Bool

    private enum Panel: String, Identifiable {
        case info, insert
        var id: Self { self }
    }

    private enum MediaDestination: Identifiable {
        case insert(after: UUID?)
        case edit(UUID)
        case attachments

        var confirmationVerb: String {
            switch self {
            case .insert: "插入"
            case .edit: "保留"
            case .attachments: "关联"
            }
        }

        var id: String {
            switch self {
            case .insert: "insert"
            case .edit(let id): id.uuidString
            case .attachments: "attachments"
            }
        }
    }

    private enum UndoAction {
        case delete(NoteCard, Int)
        case move(UUID, Int)
    }

    init(library: AppLibrary, entry: LibraryEntry) {
        self.library = library
        _entry = State(initialValue: entry)
        _persistedEntry = State(initialValue: entry)
        let matches = entry.cardContentMatchesMarkdown
        _externalChange = State(initialValue: !matches)
        let initial = (matches ? entry.noteCards : nil) ??
            (NoteCard.fromMarkdown(entry.body) + entry.itinerary.map { NoteCard(kind: .itinerary, stop: $0) })
        let hasPlaceholder = initial.isEmpty && entry.noteCards == nil
        let fresh = hasPlaceholder &&
            entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _startingWithText = State(initialValue: fresh)
        _cards = State(initialValue: hasPlaceholder ? [NoteCard(kind: .text)] : initial)
    }

    var body: some View {
        NavigationStack {
            List {
                noteHeader
                if externalChange { externalChangeRow }
                if preview {
                    NoteCardsReading(library: library, entry: entry, includeItinerary: true)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
                        .listRowBackground(Color.kinenPaper)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(cards) { card in
                        cardRow(card)
                    }
                    .onMove { offsets, destination in
                        guard let index = offsets.first, !externalChange else { return }
                        move(from: index, to: destination > index ? destination - 1 : destination)
                    }
                    Button("在末尾添加", systemImage: "plus") {
                        selected = nil
                        focusedCard = nil
                        panel = .insert
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.kinenMuted)
                    .frame(minHeight: 44)
                    .disabled(externalChange)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.kinenPaper)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                        Button("重试保存草稿") { queueAutosave(immediately: true) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.kinenPaper)
            .disabled(saving || closing)
            .environment(\.editMode, .constant(sorting ? .active : .inactive))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { undoBar }
            .navigationTitle(preview ? "预览笔记" : "编辑笔记")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard startingWithText else { return }
                startingWithText = false
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                if panel == nil, picker == nil, !preview, focusedCard == nil {
                    focusedCard = cards.first?.id
                }
            }
            .onChange(of: entry) { _, _ in queueAutosave() }
            .onChange(of: focusedCard) { _, id in if let id { selected = id } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    flushPendingText()
                    queueAutosave(immediately: true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { actionBar }
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { finish(.keepDraft) }.disabled(saving || closing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { finish(.publish) }
                        .disabled(saving || closing || !canPublish)
                }
            }
            .sheet(item: $panel, onDismiss: {
                picker = deferredPicker
                deferredPicker = nil
                if let focusAfterInsertion {
                    focusedCard = focusAfterInsertion
                    self.focusAfterInsertion = nil
                }
            }) { which in
                switch which {
                case .info: infoPanel
                case .insert: insertPanel
                }
            }
            .fullScreenCover(item: $picker) { destination in
                NoteMediaPicker(library: library, initial: initialMedia(for: destination), linked: Set(entry.mediaIds),
                                confirmationVerb: destination.confirmationVerb) { media in
                    applyMedia(media, to: destination)
                }
            }
            .confirmationDialog("删除锁定的卡片？", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible, presenting: pendingDeletion) { card in
                Button("删除卡片", role: .destructive) { delete(card.id) }
                Button("取消", role: .cancel) {}
            } message: { card in
                Text("\(card.kind.title)已锁定。删除会从笔记中移除这张卡片，关联的照片和视频仍保留在资料库。")
            }
            .confirmationDialog("丢弃这份草稿？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("丢弃草稿", role: .destructive) { finish(.discard) }
                Button("取消", role: .cancel) {}
            } message: { Text("已经完成的笔记会保留。") }
            .interactiveDismissDisabled()
        }
        .tint(Color.kinenInk)
    }

    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("笔记标题", text: $entry.title,
                      prompt: Text(canPublish ? suggestedTitle : "标题（可不填）"), axis: .vertical)
                .font(.largeTitle.weight(.semibold))
                .disabled(preview)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    noteInfoButton
                    if let draftStatus {
                        Text(draftStatus).font(.caption).fixedSize()
                    }
                }
                noteInfoButton
            }
            .foregroundStyle(Color.kinenMuted)
            .padding(.bottom, 4)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(Color.kinenPaper)
        .listRowSeparator(.hidden)
    }

    private var noteInfoButton: some View {
        Button {
            focusedCard = nil
            panel = .info
        } label: {
            Label("\(entry.kind.title) · \(entry.startDate)", systemImage: "chevron.right")
                .font(.subheadline)
                .monospacedDigit()
                .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开笔记信息")
    }

    private var draftStatus: String? {
        if hasPendingText || entry != persistedEntry { return "正在保存…" }
        return hasDraft ? "草稿已保存" : nil
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("插入", systemImage: "plus") {
                focusedCard = nil
                panel = .insert
            }
            .disabled(preview || externalChange)
            Button(preview ? "继续编辑" : "预览", systemImage: preview ? "pencil" : "eye") {
                if preview {
                    preview = false
                    focusedCard = previewFocus
                    previewFocus = nil
                } else {
                    previewFocus = focusedCard
                    focusedCard = nil
                    sorting = false
                    flushPendingText()
                    preview = true
                }
            }
            .labelStyle(.iconOnly)
            Menu("更多", systemImage: "ellipsis.circle") {
                Button(sorting ? "完成排序" : "拖拽排序", systemImage: "arrow.up.arrow.down") {
                    focusedCard = nil
                    sorting.toggle()
                }
                .disabled(preview || externalChange || cards.count < 2)
                Button("仅关联媒体", systemImage: "paperclip") {
                    focusedCard = nil
                    picker = .attachments
                }
                Button("丢弃草稿", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
                    .disabled(!hasDraft && entry == persistedEntry && !hasPendingText)
            }
            .labelStyle(.iconOnly)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderless)
        .disabled(saving || closing)
    }

    private var externalChangeRow: some View {
        Section {
            Text("正文已在外部修改。原卡片和锁定状态仍保留在笔记记录中。")
            Button("使用外部正文重建卡片") {
                externalChange = false
                updateCards(cards)
            }
            Button("恢复先前的卡片版本") {
                guard let previous = entry.noteCards else { return }
                externalChange = false
                updateCards(previous)
            }
        } header: {
            Text("检查 Markdown 更改")
        }
    }

    private func cardRow(_ card: NoteCard) -> some View {
        HStack(alignment: .top, spacing: 2) {
            if !sorting {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.kinenMuted.opacity(selected == card.id ? 1 : 0.48))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
                    .onDrag {
                        focusedCard = nil
                        dragging = card.id
                        return NSItemProvider(object: card.id.uuidString as NSString)
                    }
                    .accessibilityLabel("拖动\(card.kind.title)")
                    .accessibilityAction(named: Text("上移")) { move(card.id, offset: -1) }
                    .accessibilityAction(named: Text("下移")) { move(card.id, offset: 1) }
            }
            cardContent(card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.leading, 5)
                .background(alignment: .leading) {
                    if card.kind == .quote || focusedCard == card.id {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.kinenInk.opacity(focusedCard == card.id ? 0.4 : 0.13))
                            .frame(width: 2)
                            .padding(.vertical, 8)
                    }
                }
            cardMenu(card)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.kinenPaper)
        .overlay(alignment: dropBelow(card.id) ? .bottom : .top) {
            if dropTarget == card.id, let dragging, dragging != card.id {
                Rectangle().fill(Color.kinenInk).frame(height: 2)
            }
        }
        .dropDestination(for: String.self) { values, _ in
            defer { dragging = nil; dropTarget = nil }
            guard !externalChange, let value = values.first, let from = UUID(uuidString: value),
                  from == dragging else { return false }
            return move(from, onto: card.id)
        } isTargeted: { isTargeted in
            dropTarget = isTargeted ? card.id : (dropTarget == card.id ? nil : dropTarget)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { toggleLock(card.id) } label: {
                Label(card.locked ? "解锁" : "锁定", systemImage: card.locked ? "lock.open" : "lock")
            }
            .tint(.gray)
            Button { requestDeletion(card) } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
        }
        .disabled(externalChange)
    }

    private func cardMenu(_ card: NoteCard) -> some View {
        Menu {
            if card.kind == .media && !card.locked {
                Button("调整媒体", systemImage: "photo.badge.plus") {
                    focusedCard = nil
                    picker = .edit(card.id)
                }
            }
            Button("在此卡片后插入", systemImage: "plus") {
                selected = card.id
                focusedCard = nil
                panel = .insert
            }
            Button("上移", systemImage: "arrow.up") { move(card.id, offset: -1) }
                .disabled(cards.first?.id == card.id)
            Button("下移", systemImage: "arrow.down") { move(card.id, offset: 1) }
                .disabled(cards.last?.id == card.id)
            Button(card.locked ? "解锁" : "锁定", systemImage: card.locked ? "lock.open" : "lock") { toggleLock(card.id) }
            Button("删除", systemImage: "trash", role: .destructive) { requestDeletion(card) }
        } label: {
            Image(systemName: card.locked ? "lock.fill" : "ellipsis")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.kinenMuted.opacity(card.locked || selected == card.id ? 1 : 0.48))
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(card.locked ? "已锁定，\(card.kind.title)操作" : "\(card.kind.title)操作")
    }

    @ViewBuilder
    private func cardContent(_ card: NoteCard) -> some View {
        switch card.kind {
        case .divider:
            Divider().padding(.vertical, 5)
        case .media:
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(card.media.enumerated()), id: \.offset) { _, media in
                        if let item = library.snapshot.mediaByID[media.id] {
                            if item.kind == .video {
                                NavigationLink {
                                    MediaDetail(library: library, item: item)
                                } label: { NoteMediaThumbnail(library: library, item: item).frame(width: 92, height: 92) }
                                    .buttonStyle(.plain)
                            } else {
                                NoteMediaThumbnail(library: library, item: item).frame(width: 92, height: 92)
                            }
                        } else {
                            Image(systemName: "photo").frame(width: 92, height: 92)
                                .accessibilityLabel("附件缺失")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        case .itinerary:
            if let stop = card.stop {
                if card.locked {
                    Text("\(stop.date) · \(stop.title)").textSelection(.enabled)
                } else {
                    TravelStopFields(stop: Binding(
                        get: { cards.first { $0.id == card.id }?.stop ?? stop },
                        set: { value in modify(card.id) { $0.stop = value } }
                    ), tripStart: entry.startDate, tripEnd: entry.endDate ?? entry.startDate)
                }
            }
        case .relatedNote:
            if let id = card.noteID {
                NavigationLink {
                    JournalDetail(library: library, id: id)
                } label: {
                    Label(library.snapshot.entriesByID[id]?.title ?? card.text, systemImage: "link")
                }
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if card.kind == .bullets || card.kind == .numbered {
                    Text(card.kind == .bullets ? "•" : "1.")
                        .foregroundStyle(Color.kinenMuted)
                        .accessibilityHidden(true)
                }
                if card.locked {
                    Text(card.text.isEmpty ? "空卡片" : card.text)
                        .textSelection(.enabled)
                } else {
                    TextField(card.kind == .text && cards.first?.id == card.id ? "写下这一刻…" : card.kind.title, text: Binding(
                        get: { cards.first { $0.id == card.id }?.text ?? "" },
                        set: { value in editText(value, in: card.id) }
                    ), axis: .vertical)
                        .lineLimit(1...)
                        .focused($focusedCard, equals: card.id)
                        .accessibilityLabel(card.kind.title)
                }
            }
            .font(card.kind == .heading ? .title3.weight(.semibold) : .body)
        }
    }

    private var undoBar: some View {
        Group {
            if let undo {
                HStack {
                    switch undo {
                    case .delete: Text("已删除卡片")
                    case .move: Text("已移动卡片")
                    }
                    Spacer()
                    Button("撤销") { undoLast() }.fontWeight(.semibold)
                    Button("关闭提示", systemImage: "xmark") { self.undo = nil }.labelStyle(.iconOnly)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .kinenCard(radius: 14)
                .padding(.horizontal, 12)
            }
        }
    }

    private func editText(_ text: String, in id: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }),
              !cards[index].locked, !externalChange, cards[index].text != text else { return }
        cards[index].text = text
        hasPendingText = true
        textProjection?.cancel()
        textProjection = Task {
            do { try await Task.sleep(for: .milliseconds(220)) }
            catch { return }
            flushPendingText()
        }
    }

    private func flushPendingText() {
        if hasPendingText { updateCards(cards) }
    }

    private func modify(_ id: UUID, change: (inout NoteCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }), !cards[index].locked, !externalChange else { return }
        var updated = cards
        change(&updated[index])
        updateCards(updated)
    }

    private func toggleLock(_ id: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }), !externalChange else { return }
        focusedCard = nil
        var updated = cards
        updated[index].locked.toggle()
        updateCards(updated)
    }

    private func requestDeletion(_ card: NoteCard) {
        focusedCard = nil
        if card.locked { pendingDeletion = card } else { delete(card.id) }
    }

    private func delete(_ id: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }), !externalChange else { return }
        var updated = cards
        let card = updated.remove(at: index)
        if selected == id { selected = nil }
        undo = .delete(card, index)
        updateCards(updated)
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        move(from: index, to: index + offset)
    }

    private func dropBelow(_ id: UUID) -> Bool {
        guard let dragging, let from = cards.firstIndex(where: { $0.id == dragging }),
              let target = cards.firstIndex(where: { $0.id == id }) else { return false }
        return from < target
    }

    @discardableResult
    private func move(_ id: UUID, onto target: UUID) -> Bool {
        guard let source = cards.firstIndex(where: { $0.id == id }),
              let destination = cards.firstIndex(where: { $0.id == target }), source != destination else { return false }
        move(from: source, to: destination)
        return true
    }

    private func move(from index: Int, to destination: Int) {
        guard cards.indices.contains(destination), index != destination, !externalChange else { return }
        focusedCard = nil
        var updated = cards
        let card = updated.remove(at: index)
        updated.insert(card, at: destination)
        updateCards(updated)
        undo = .move(card.id, index)
    }

    private func undoLast() {
        guard let undo else { return }
        var updated = cards
        switch undo {
        case .delete(let card, let index):
            updated.insert(card, at: min(index, updated.count))
        case .move(let id, let index):
            guard let current = updated.firstIndex(where: { $0.id == id }) else { return }
            let card = updated.remove(at: current)
            updated.insert(card, at: min(index, updated.count))
        }
        self.undo = nil
        updateCards(updated)
    }

    @State private var projectedInlineMedia: Set<UUID>?

    private var inlineMediaIDs: Set<UUID> {
        projectedInlineMedia ?? NoteMarkdownBlock.mediaIDs(in: entry.body)
    }

    private func updateCards(_ updated: [NoteCard], attachments: [UUID]? = nil) {
        textProjection?.cancel()
        textProjection = nil
        hasPendingText = false
        let previousInline = inlineMediaIDs
        let attachments = attachments ?? entry.mediaIds.filter { !previousInline.contains($0) }
        cards = updated
        var updatedEntry = entry
        updatedEntry.replaceNoteCards(updated)
        let inline = updatedEntry.body == entry.body ? previousInline : NoteMarkdownBlock.mediaIDs(in: updatedEntry.body)
        projectedInlineMedia = inline
        let ordered = updated.flatMap { $0.media.map(\.id) } + inline.sorted { $0.uuidString < $1.uuidString }
        let available = library.snapshot.mediaByID
        var seen = Set<UUID>()
        updatedEntry.mediaIds = (attachments + ordered).filter { available[$0] != nil && seen.insert($0).inserted }
        if let cover = updatedEntry.coverMediaId, !seen.contains(cover) { updatedEntry.coverMediaId = nil }
        entry = updatedEntry
    }

    private var insertPanel: some View {
        NavigationStack {
            List {
                Section {
                    Button { insert(.text) } label: { Label("写一段文字", systemImage: NoteCard.Kind.text.icon) }
                    Button { insert(.media) } label: { Label("插入照片或视频", systemImage: NoteCard.Kind.media.icon) }
                } header: {
                    if let selected, let current = cards.first(where: { $0.id == selected }) {
                        Text("插在「\(current.kind.title)」之后")
                    } else { Text("插在文末") }
                }
                Section {
                    DisclosureGroup("更多卡片") {
                        ForEach([NoteCard.Kind.heading, .bullets, .numbered, .quote, .divider, .markdown], id: \.self) { kind in
                            Button { insert(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                        }
                        if entry.kind == .trip {
                            Button("行程项", systemImage: NoteCard.Kind.itinerary.icon) { insert(.itinerary) }
                        }
                        if !relatedEntries.isEmpty {
                            NavigationLink { relatedList } label: {
                                Label("关联笔记", systemImage: "link")
                            }
                        }
                    }
                }
            }
            .kinenListStyle()
            .navigationTitle("插入卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { panel = nil } }
        }
        .presentationDetents([.medium, .large])
    }

    private var relatedEntries: [LibraryEntry] {
        library.snapshot.entries.filter { $0.parentId == entry.id || $0.id == entry.parentId }
    }


    private var relatedList: some View {
        List(relatedEntries) { note in
            Button {
                insertCard(NoteCard(kind: .relatedNote, text: note.title, noteID: note.id), after: selected)
                panel = nil
            } label: { JournalRow(entry: note) }
        }
        .kinenListStyle()
        .navigationTitle("关联笔记")
    }

    private func insert(_ kind: NoteCard.Kind) {
        if kind == .media {
            deferredPicker = .insert(after: selected)
        } else {
            let stop = kind == .itinerary ? TravelStop(date: entry.itinerary.last?.date ?? entry.startDate) : nil
            let inserted = NoteCard(kind: kind, stop: stop)
            insertCard(inserted, after: selected)
            if [.text, .heading, .quote, .bullets, .numbered, .markdown].contains(kind) {
                focusAfterInsertion = inserted.id
            }
        }
        panel = nil
    }

    private func insertCard(_ card: NoteCard, after anchor: UUID?) {
        var updated = cards
        let index = anchor.flatMap { id in updated.firstIndex { $0.id == id } }.map { $0 + 1 } ?? updated.count
        if entry.noteCards == nil, updated.count == 1, let first = updated.first, first.kind == .text,
           !first.locked, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated[0] = card
        } else {
            updated.insert(card, at: index)
        }
        selected = card.id
        updateCards(updated)
    }

    private func initialMedia(for destination: MediaDestination) -> [UUID] {
        switch destination {
        case .insert: return []
        case .edit(let id): return cards.first { $0.id == id }?.media.map(\.id) ?? []
        case .attachments:
            let inline = inlineMediaIDs
            return entry.mediaIds.filter { !inline.contains($0) }
        }
    }

    private func applyMedia(_ choices: [UUID], to destination: MediaDestination) {
        switch destination {
        case .attachments:
            let inline = inlineMediaIDs
            let available = library.snapshot.mediaByID
            var seen = Set<UUID>()
            entry.mediaIds = (choices + entry.mediaIds.filter { inline.contains($0) })
                .filter { available[$0] != nil && seen.insert($0).inserted }
            if let cover = entry.coverMediaId, !seen.contains(cover) { entry.coverMediaId = nil }
        case .insert(let anchor):
            guard !choices.isEmpty, !externalChange else { return }
            insertCard(NoteCard(kind: .media, media: makeReferences(choices)), after: anchor)
        case .edit(let id):
            let fallback = cards.first { $0.id == id }?.media ?? []
            if choices.isEmpty {
                if let card = cards.first(where: { $0.id == id }) { requestDeletion(card) }
            } else {
                modify(id) { $0.media = makeReferences(choices, fallback: fallback) }
            }
        }
    }

    private func makeReferences(_ choices: [UUID], fallback: [NoteCard.Media] = []) -> [NoteCard.Media] {
        choices.map { id in
            if let item = library.snapshot.mediaByID[id] {
                return NoteCard.Media(id: id, label: item.kind.title, video: item.kind == .video)
            }
            return fallback.first { $0.id == id } ?? NoteCard.Media(id: id, label: "缺失媒体", video: false)
        }
    }

    private var infoPanel: some View {
        NavigationStack {
            Form {
                Section("属性") {
                    if entry.itinerary.isEmpty {
                        Picker("类型", selection: $entry.kind) {
                            ForEach(EntryKind.allCases) { Text($0.title).tag($0) }
                        }
                    } else {
                        LabeledContent("类型", value: entry.kind.title)
                    }
                    DatePicker("开始日期", selection: day(\.startDate), displayedComponents: .date)
                    if entry.kind == .trip {
                        DatePicker("结束日期", selection: Binding(
                            get: { LocalDay.date(from: entry.endDate ?? entry.startDate) ?? .now },
                            set: { entry.endDate = LocalDay.string(from: $0) }
                        ), displayedComponents: .date)
                    }
                    TextField("地点（选填）", text: Binding(get: { entry.location ?? "" },
                                                         set: { entry.location = $0.isEmpty ? nil : $0 }))
                    Picker("归属", selection: $entry.parentId) {
                        Text("独立笔记").tag(nil as UUID?)
                        ForEach(library.snapshot.entries.filter { $0.id != entry.id && $0.kind.allowsChild(entry.kind) }) {
                            Text($0.title).tag(Optional($0.id))
                        }
                    }
                }
                Section("媒体") {
                    Button("仅关联媒体", systemImage: "paperclip") {
                        deferredPicker = .attachments
                        panel = nil
                    }
                    let coverItems = library.snapshot.media.filter { entry.mediaIds.contains($0.id) && $0.kind != .video }
                    if !coverItems.isEmpty {
                        Picker("封面", selection: $entry.coverMediaId) {
                            Text("自动选择").tag(nil as UUID?)
                            ForEach(coverItems) { item in
                                Text("\(item.kind.title) · \(item.captureDate ?? "日期未知")").tag(Optional(item.id))
                            }
                        }
                    }
                }
            }
            .kinenListStyle()
            .navigationTitle("笔记信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { panel = nil } }
            .onChange(of: entry.kind) { _, kind in
                if kind != .trip { entry.endDate = nil }
                if let parent = entry.parentId.flatMap({ library.snapshot.entriesByID[$0] }),
                   !parent.kind.allowsChild(kind) { entry.parentId = nil }
            }
        }
    }

    private func day(_ key: WritableKeyPath<LibraryEntry, String>) -> Binding<Date> {
        Binding(get: { LocalDay.date(from: entry[keyPath: key]) ?? .now },
                set: { entry[keyPath: key] = LocalDay.string(from: $0) })
    }
    private var canPublish: Bool {
        !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !entry.mediaIds.isEmpty || cards.contains { card in
                !card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !card.media.isEmpty || card.noteID != nil ||
                    card.stop.map { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
            }
    }

    private var suggestedTitle: String {
        NoteCard.suggestedTitle(from: cards, fallback: "\(entry.kind.title) · \(entry.startDate)")
    }

    private var hasDraft: Bool { savedDraftInSession || library.drafts.contains { $0.id == entry.id } }

    private func queueAutosave(immediately: Bool = false) {
        guard !saving, !closing else { return }
        let previous = autosave
        previous?.cancel()
        let candidate = entry
        autosave = Task {
            await previous?.value
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                guard candidate != persistedEntry else { return }
                try await library.store.saveDraft(candidate)
                persistedEntry = candidate
                savedDraftInSession = true
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private enum FinishAction { case keepDraft, publish, discard }

    private func finish(_ action: FinishAction) {
        guard !closing, action != .publish || canPublish else { return }
        if action != .discard { flushPendingText() }
        textProjection?.cancel()
        let pending = autosave
        pending?.cancel()
        closing = true
        saving = action == .publish
        errorMessage = nil
        var candidate = entry
        if action == .publish, candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate.title = suggestedTitle
        }
        if let cover = candidate.coverMediaId, !candidate.mediaIds.contains(cover),
           !NoteMarkdownBlock.mediaIDs(in: candidate.body).contains(cover) {
            candidate.coverMediaId = nil
        }
        if candidate.kind == .trip, candidate.endDate == nil, action == .publish {
            candidate.endDate = candidate.startDate
        }
        Task {
            defer {
                closing = false
                saving = false
            }
            await pending?.value
            do {
                switch action {
                case .keepDraft:
                    if candidate != persistedEntry { try await library.store.saveDraft(candidate) }
                case .publish:
                    if entry != persistedEntry {
                        try await library.store.saveDraft(entry)
                        persistedEntry = entry
                        await library.reloadDrafts()
                    }
                    try await library.store.publishDraft(candidate)
                case .discard:
                    try await library.store.discardDraft(candidate.id)
                }
                if action == .publish { await library.reload() }
                else { await library.reloadDrafts() }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}

private extension NoteCard.Kind {
    var title: String {
        switch self {
        case .text: "段落"
        case .heading: "标题"
        case .quote: "引用"
        case .bullets: "项目列表"
        case .numbered: "编号列表"
        case .media: "照片与视频"
        case .divider: "分隔线"
        case .markdown: "Markdown"
        case .itinerary: "行程项"
        case .relatedNote: "关联笔记"
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .heading: "textformat.size"
        case .quote: "quote.opening"
        case .bullets: "list.bullet"
        case .numbered: "list.number"
        case .media: "photo.on.rectangle"
        case .divider: "minus"
        case .markdown: "chevron.left.forwardslash.chevron.right"
        case .itinerary: "mappin"
        case .relatedNote: "link"
        }
    }
}
