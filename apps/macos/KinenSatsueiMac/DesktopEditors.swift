import KinenCore
import SwiftUI

struct DesktopNoteEditor: View {
    let library: DesktopLibrary
    @State var entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var preview = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑笔记").font(.title2.bold())
                Spacer()
                Button("关闭") { save(publish: false) }.keyboardShortcut(.cancelAction)
                Button("完成") { save(publish: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Form {
                TextField("标题", text: $entry.title)
                Picker("类型", selection: $entry.kind) {
                    ForEach(EntryKind.allCases) { kind in Text(kind.label).tag(kind) }
                }
                .disabled(!entry.itinerary.isEmpty)
                DatePicker("开始日期", selection: day(\LibraryEntry.startDate), displayedComponents: .date)
                if entry.kind == .trip {
                    DatePicker("结束日期", selection: Binding(
                        get: { LocalDay.date(from: entry.endDate ?? entry.startDate) ?? .now },
                        set: { entry.endDate = LocalDay.string(from: $0) }
                    ), displayedComponents: .date)
                }
                Picker("归属", selection: $entry.parentId) {
                    Text("独立笔记").tag(nil as UUID?)
                    ForEach(library.snapshot.entries.filter { $0.id != entry.id && $0.kind.allowsChild(entry.kind) }) { parent in
                        Text(parent.title).tag(Optional(parent.id))
                    }
                }
            }
            Picker("显示", selection: $preview) {
                Text("编辑").tag(false)
                Text("预览").tag(true)
            }
            .pickerStyle(.segmented)
            if preview {
                ScrollView { DesktopMarkdown(source: entry.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 160)
            } else {
                TextEditor(text: $entry.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .accessibilityLabel("Markdown 正文")
            }
            if !library.snapshot.media.isEmpty {
                Menu("关联媒体") {
                    ForEach(library.snapshot.media) { item in
                        Toggle("\(item.kind.label) · \(item.captureDate ?? "日期未知")", isOn: Binding(
                            get: { entry.mediaIds.contains(item.id) },
                            set: { enabled in
                                if enabled, !entry.mediaIds.contains(item.id) { entry.mediaIds.append(item.id) }
                                if !enabled { entry.mediaIds.removeAll { $0 == item.id } }
                            }
                        ))
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 500)
        .disabled(busy)
        .interactiveDismissDisabled()
        .onChange(of: entry.kind) { _, kind in
            if kind != .trip { entry.endDate = nil }
            if let parent = library.snapshot.entries.first(where: { $0.id == entry.parentId }),
               !parent.kind.allowsChild(kind) { entry.parentId = nil }
        }
    }

    private func day(_ key: WritableKeyPath<LibraryEntry, String>) -> Binding<Date> {
        Binding(get: { LocalDay.date(from: entry[keyPath: key]) ?? .now },
                set: { entry[keyPath: key] = LocalDay.string(from: $0) })
    }

    private func save(publish: Bool) {
        busy = true
        var candidate = entry
        if candidate.kind == .trip && candidate.endDate == nil { candidate.endDate = candidate.startDate }
        Task {
            defer { busy = false }
            do {
                if publish {
                    try await library.store.publishDraft(candidate)
                } else if !candidate.title.isEmpty || !candidate.body.isEmpty || !candidate.mediaIds.isEmpty {
                    try await library.store.saveDraft(candidate)
                }
                await library.reload()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct DesktopMarkdown: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(NoteMarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text)
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? .title.bold() : .headline)
                case .listItem(let marker, let text):
                    HStack(alignment: .firstTextBaseline) { Text(marker); inline(text) }
                case .quote(let text):
                    inline(text).italic().foregroundStyle(.secondary).padding(.leading, 10)
                case .code(let text):
                    Text(verbatim: text).font(.system(.body, design: .monospaced)).padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                case .divider: Divider()
                case .media(_, let label):
                    Label(label.isEmpty ? "关联媒体" : label, systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map(Text.init) ?? Text(verbatim: text)
    }
}

struct DesktopImportView: View {
    let library: DesktopLibrary
    let request: DesktopImport
    @Environment(\.dismiss) private var dismiss
    @State private var waiting: [DesktopImport.Item]?
    @State private var imageKind = MediaKind.photo
    @State private var subject: ChekiSubject?
    @State private var date = Date.now
    @State private var knowsDate = false
    @State private var working = false

    var body: some View {
        let items = waiting ?? request.items
        VStack(alignment: .leading, spacing: 14) {
            Text("导入 \(items.count) 项媒体").font(.title2.bold())
            Form {
                if items.contains(where: { !$0.isVideo }) {
                    Picker("照片类型", selection: $imageKind) {
                        ForEach([MediaKind.photo, .portrait, .cheki]) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if imageKind == .cheki {
                        Picker("成员或团体", selection: $subject) {
                            Text("请选择").tag(nil as ChekiSubject?)
                            ForEach(library.snapshot.members.filter { !$0.archived }) { member in
                                Text(member.name).tag(Optional(ChekiSubject.member(member.id)))
                            }
                            ForEach(library.snapshot.groups) { group in
                                Text(group.name).tag(Optional(ChekiSubject.group(group.id)))
                            }
                        }
                    }
                }
                if imageKind != .cheki { Toggle("已知拍摄日期", isOn: $knowsDate) }
                if knowsDate || imageKind == .cheki {
                    DatePicker("拍摄日期", selection: $date, displayedComponents: .date)
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(waiting == nil ? "导入" : "重试剩余项目") {
                    working = true
                    Task {
                        let selectedDate = knowsDate || imageKind == .cheki ? LocalDay.string(from: date) : nil
                        let failed = await library.importMedia(DesktopImport(items: items), imageKind: imageKind,
                                                               subject: subject, date: selectedDate)
                        working = false
                        if failed.isEmpty { dismiss() }
                        else { waiting = failed }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(imageKind == .cheki && items.contains(where: { !$0.isVideo }) && subject == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(working)
        .interactiveDismissDisabled(working)
    }
}

struct DesktopSettings: View {
    let library: DesktopLibrary
    @State private var newName = ""
    @State private var isGroup = false
    @State private var gitPanel: GitPanel?

    private enum GitPanel: String, Identifiable {
        case sync, keys
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section("资料库") {
                Picker("当前资料库", selection: Binding(get: { library.activeName }, set: library.switchLibrary(to:))) {
                    ForEach(library.libraryNames, id: \.self) { id in Text(library.libraryLabel(id)).tag(id) }
                }
                Button("导出备份…") { library.backup(restore: false) }
                Button("恢复备份…") { library.backup(restore: true) }
            }
            Section("Git") {
                Button("Git 同步…") { gitPanel = .sync }
                Button("SSH 密钥…") { gitPanel = .keys }
            }
            Section("成员和团体") {
                TextField("名称", text: $newName)
                Toggle("团体", isOn: $isGroup)
                Button("新增") {
                    library.addSubject(newName, group: isGroup)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(library.snapshot.members) { Label($0.name, systemImage: "person") }
                ForEach(library.snapshot.groups) { Label($0.name, systemImage: "person.3") }
            }
        }
        .formStyle(.grouped)
        .disabled(library.busy)
        .navigationTitle("设置")
        .sheet(item: $gitPanel) { panel in
            NavigationStack {
                Group {
                    switch panel {
                    case .sync: GitSyncSettings(library: library)
                    case .keys: GitSSHIdentitySettings(connectionID: library.store.root.lastPathComponent)
                    }
                }
                .toolbar { Button("关闭") { gitPanel = nil }.keyboardShortcut(.cancelAction) }
            }
            .frame(minWidth: 540, minHeight: 500)
        }
    }
}
