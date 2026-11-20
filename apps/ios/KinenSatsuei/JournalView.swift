import KinenCore
import SwiftUI

struct JournalList: View {
    let library: AppLibrary
    @State private var creating = false

    var body: some View {
        List(library.snapshot.entries) { entry in
            NavigationLink {
                JournalDetail(library: library, id: entry.id)
            } label: {
                JournalRow(entry: entry)
            }
        }
        .overlay {
            if library.snapshot.entries.isEmpty {
                ContentUnavailableView("还没有手帐", systemImage: "book",
                                       description: Text("点右上角开始记录。"))
            }
        }
        .navigationTitle("手帐")
        .toolbar {
            Button("新建手帐", systemImage: "square.and.pencil") { creating = true }
        }
        .sheet(isPresented: $creating) { JournalEditor(library: library, entry: LibraryEntry()) }
    }
}

struct JournalRow: View {
    let entry: LibraryEntry

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(entry.title)
                Text("\(entry.kind.title) · \(entry.startDate)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: entry.kind.icon)
        }
    }
}

struct JournalDetail: View {
    let library: AppLibrary
    let id: UUID
    @State private var editing = false

    var body: some View {
        if let entry = library.snapshot.entries.first(where: { $0.id == id }) {
            List {
                Section {
                    LabeledContent(entry.kind.title, value: entry.endDate.map { "\(entry.startDate) 至 \($0)" } ?? entry.startDate)
                    if !entry.body.isEmpty { MarkdownBody(source: entry.body) }
                }
                let children = library.snapshot.entries.filter { $0.parentId == id }
                if !children.isEmpty {
                    Section("相关手帐") {
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
                            if let item = library.snapshot.media.first(where: { $0.id == mediaId }) {
                                NavigationLink {
                                    MediaDetail(library: library, item: item)
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
            .navigationTitle(entry.title)
            .toolbar { Button("编辑") { editing = true } }
            .sheet(isPresented: $editing) { JournalEditor(library: library, entry: entry) }
        }
    }
}

struct JournalEditor: View {
    let library: AppLibrary
    @State var entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var preview = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $entry.title)
                    Picker("类型", selection: $entry.kind) {
                        ForEach(EntryKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    DatePicker("开始日期", selection: day(\LibraryEntry.startDate), displayedComponents: .date)
                    if entry.kind == .trip {
                        DatePicker("结束日期", selection: endDay, displayedComponents: .date)
                    }
                    Picker("归属", selection: $entry.parentId) {
                        Text("独立手帐").tag(nil as UUID?)
                        ForEach(library.snapshot.entries.filter { $0.id != entry.id && $0.kind.allowsChild(entry.kind) }) {
                            Text($0.title).tag(Optional($0.id))
                        }
                    }
                }
                Section {
                    Picker("正文", selection: $preview) {
                        Text("编辑").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if preview { MarkdownBody(source: entry.body) }
                    else {
                        TextEditor(text: $entry.body)
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                            .accessibilityLabel("Markdown 正文")
                    }
                }
                if !library.snapshot.media.isEmpty {
                    Section("关联媒体") {
                        ForEach(library.snapshot.media) { item in
                            Toggle(isOn: Binding(
                                get: { entry.mediaIds.contains(item.id) },
                                set: { chosen in
                                    if chosen { entry.mediaIds.append(item.id) }
                                    else { entry.mediaIds.removeAll { $0 == item.id } }
                                }
                            )) { MediaRow(library: library, item: item) }
                        }
                    }
                }
            }
            .navigationTitle("写手帐")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: entry.kind) { _, kind in
                if kind != .trip { entry.endDate = nil }
                if let parent = library.snapshot.entries.first(where: { $0.id == entry.parentId }),
                   !parent.kind.allowsChild(kind) { entry.parentId = nil }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        var edited = entry
                        if edited.kind == .trip, edited.endDate == nil { edited.endDate = edited.startDate }
                        saving = true
                        Task {
                            if await library.perform({ try await library.store.save(edited) }) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func day(_ key: WritableKeyPath<LibraryEntry, String>) -> Binding<Date> {
        Binding(get: { formatter.date(from: entry[keyPath: key]) ?? .now },
                set: { entry[keyPath: key] = LocalDay.string(from: $0) })
    }

    private var endDay: Binding<Date> {
        Binding(get: { formatter.date(from: entry.endDate ?? entry.startDate) ?? .now },
                set: { entry.endDate = LocalDay.string(from: $0) })
    }
}

struct MarkdownBody: View {
    let source: String

    var body: some View {
        if let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(markdown)
                .environment(\.openURL, OpenURLAction { url in
                    let allowed = ["http", "https", "mailto"]
                    return allowed.contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                })
        } else {
            Text(source)
        }
    }
}
