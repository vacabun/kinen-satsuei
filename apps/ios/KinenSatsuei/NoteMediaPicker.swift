import AVKit
import KinenCore
import SwiftUI

struct NoteMediaPicker: View {
    let library: AppLibrary
    let linked: Set<UUID>
    let onConfirm: ([UUID]) -> Void
    let allowsEmptySelection: Bool
    let confirmationVerb: String

    @Environment(\.dismiss) private var dismiss
    @State private var selection: [UUID]
    @State private var showsMoreFilters = false
    @State private var subject = Subject.all
    @State private var dateBasis = CollectionDateBasis.capture
    @State private var period: String?
    @State private var limitsDates = false
    @State private var dateStart = Date.now
    @State private var dateEnd = Date.now
    @State private var mediaKind: MediaKind?
    @State private var query = ""
    @State private var reviewing = false
    @State private var previewItem: LibraryMedia?
    @ScaledMetric(relativeTo: .caption) private var tileWidth = 98.0
    @State private var result = ResultSet()
    @State private var displayedRequest: Request?

    private enum Subject: Hashable, Sendable { case all, member(UUID), group(UUID), untagged }

    private struct Request: Equatable, Sendable {
        let revision: Int
        var groupsByMonth: Bool { period != nil || range != nil || basis == .added }
        let subject: Subject
        let basis: CollectionDateBasis
        let period: String?
        let kind: MediaKind?
        let query: String
        let range: ClosedRange<Date>?
        let zone: TimeZone
    }

    private struct ResultSet: Sendable {
        var groups: [String: [LibraryMedia]] = [:]
        var periods: [String] = []
    }

    private var request: Request {
        Request(revision: library.snapshotVersion, subject: subject, basis: dateBasis,
                period: period, kind: mediaKind, query: query, range: limitsDates ? dateStart...dateEnd : nil,
                zone: .current)
    }


    init(library: AppLibrary, initial: [UUID], linked: Set<UUID>, confirmationVerb: String = "插入",
         suggestedDay: String? = nil, onConfirm: @escaping ([UUID]) -> Void) {
        self.library = library
        self.linked = linked
        self.onConfirm = onConfirm
        self.confirmationVerb = confirmationVerb
        allowsEmptySelection = !initial.isEmpty
        var seen = Set<UUID>()
        _selection = State(initialValue: initial.filter { seen.insert($0).inserted })
        if let date = suggestedDay.flatMap(LocalDay.date(from:)) {
            _limitsDates = State(initialValue: true)
            _dateStart = State(initialValue: date)
            _dateEnd = State(initialValue: date)
        }
    }

    var body: some View {
        let request = request
        let groups = displayedRequest == request ? result.groups : [:]
        let selectedOrder = Dictionary(uniqueKeysWithValues: selection.enumerated().map { ($0.element, $0.offset + 1) })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    filters
                    if displayedRequest != request && groups.isEmpty {
                        ProgressView("正在筛选媒体…").frame(maxWidth: .infinity)
                    } else if groups.isEmpty {
                        ContentUnavailableView(library.snapshot.media.isEmpty ? "还没有照片或视频" : "没有符合条件的媒体",
                                               systemImage: "photo.on.rectangle",
                                               description: Text(library.snapshot.media.isEmpty
                                                   ? "可以先返回首页添加媒体。"
                                                   : "可以清除筛选或修改搜索词。"))
                    }
                    ForEach(groups.keys.sorted(by: >), id: \.self) { key in
                        if request.groupsByMonth {
                            Text(periodLabel(key)).font(.headline).accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 10)], spacing: 12) {
                            ForEach(groups[key] ?? []) { item in tile(item, number: selectedOrder[item.id]) }
                        }
                    }
                }
                .padding(16).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(Color.kinenCanvas)
            .navigationTitle("选择媒体")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索成员、日期或媒体备注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("已选 \(selection.count)") { reviewing = true }
                        .disabled(selection.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    onConfirm(selection)
                    dismiss()
                } label: {
                    Text(selection.isEmpty
                         ? (allowsEmptySelection ? "移除选中的媒体" : "选择照片或视频")
                         : "\(confirmationVerb) \(selection.count) 项媒体")
                        .kinenPrimaryButton()
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty && !allowsEmptySelection)
                .opacity(selection.isEmpty && !allowsEmptySelection ? 0.45 : 1)
                .padding(12).background(Color.kinenPaper)
            }
            .sheet(isPresented: $reviewing) { review }
            .sheet(item: $previewItem) { item in
                NavigationStack {
                    Group {
                        if item.kind == .video {
                            VideoPlayer(player: AVPlayer(url: library.store.displayURL(for: item)))
                        } else {
                            AssetImage(url: library.store.displayURL(for: item), maxPixels: 1400, icon: "photo",
                                       quarterTurns: item.quarterTurns ?? 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.kinenCanvas)
                    .navigationTitle(item.kind.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("关闭") { previewItem = nil } }
                }
            }
        }
        .tint(Color.kinenInk)
        .task(id: request) {
            if !request.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(140)) }
                catch { return }
            }
            let snapshot = library.snapshot
            let work = Task.detached(priority: .userInitiated) { Self.filter(snapshot, request: request) }
            let updated = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            result = updated
            displayedRequest = request
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filterActions }
                VStack(alignment: .leading, spacing: 4) { filterActions }
            }
            if showsMoreFilters {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("日期口径", selection: $dateBasis) {
                        Text("拍摄日期").tag(CollectionDateBasis.capture)
                        Text("入库日期").tag(CollectionDateBasis.added)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: dateBasis) { _, _ in period = nil }
                    Toggle("限定日期范围", isOn: $limitsDates)
                        .onChange(of: limitsDates) { _, enabled in if enabled { period = nil } }
                    if limitsDates {
                        DatePicker("从", selection: $dateStart, in: ...dateEnd, displayedComponents: .date)
                        DatePicker("到", selection: $dateEnd, in: dateStart..., displayedComponents: .date)
                    }
                    Picker("媒体类型", selection: $mediaKind) {
                        Text("全部类型").tag(nil as MediaKind?)
                        ForEach(MediaKind.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                }
                .padding(12).kinenCard(radius: 16)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var filterActions: some View {
        Menu {
            Picker("成员或团体", selection: $subject) {
                Text("全部").tag(Subject.all)
                Text("未标记成员或团体").tag(Subject.untagged)
                Section("成员") {
                    ForEach(library.snapshot.members) { member in
                        Text(member.name).tag(Subject.member(member.id))
                    }
                }
                Section("团体") {
                    ForEach(library.snapshot.groups) { group in
                        Text(group.name).tag(Subject.group(group.id))
                    }
                }
            }
        } label: { filterChip(subjectTitle, icon: "person.2", active: subject != .all) }

        Menu {
            Picker("年月", selection: Binding(
                get: { period },
                set: { month in
                    period = month
                    limitsDates = false
                }
            )) {
                Text("全部日期").tag(nil as String?)
                ForEach(result.periods, id: \.self) { Text(periodLabel($0)).tag(Optional($0)) }
            }
        } label: {
            filterChip(period.map(periodLabel) ?? dateChipTitle, icon: "calendar",
                       active: period != nil || limitsDates || dateBasis == .added)
        }
        .accessibilityHint(dateBasis == .capture ? "按拍摄日期筛选" : "按入库日期筛选")

        Button {
            showsMoreFilters.toggle()
        } label: {
            filterChip("筛选", icon: "line.3.horizontal.decrease", active: showsMoreFilters || mediaKind != nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsMoreFilters ? .isSelected : [])

        if subject != .all || period != nil || limitsDates || mediaKind != nil || dateBasis != .capture {
            Button("清除", action: clearFilters).frame(minHeight: 44)
        }
    }

    private var dateChipTitle: String {
        guard limitsDates else { return "时间" }
        let start = LocalDay.string(from: dateStart)
        return start == LocalDay.string(from: dateEnd) ? start : "日期范围"
    }

    private var subjectTitle: String {
        switch subject {
        case .all: "成员"
        case .untagged: "未标记"
        case .member(let id): library.snapshot.membersByID[id]?.name ?? "成员"
        case .group(let id): library.snapshot.groupsByID[id]?.name ?? "团体"
        }
    }

    private func filterChip(_ title: String, icon: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .foregroundStyle(active ? Color.kinenOnInk : Color.kinenInk)
            .background(active ? Color.kinenInk : Color.kinenPaper, in: Capsule())
    }

    private func clearFilters() {
        subject = .all
        period = nil
        limitsDates = false
        dateBasis = .capture
        mediaKind = nil
    }

    private func tile(_ item: LibraryMedia, number: Int?) -> some View {
        VStack(spacing: 3) {
            Button { toggle(item.id) } label: {
                Color.kinenPaper.aspectRatio(1, contentMode: .fit)
                    .overlay { NoteMediaThumbnail(library: library, item: item) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        if let number {
                            Text("\(number)").font(.caption.weight(.semibold).monospacedDigit())
                                .frame(width: 26, height: 26)
                                .foregroundStyle(Color.kinenOnInk).background(Color.kinenInk, in: Circle()).padding(5)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(number == nil ? Color.kinenLine : Color.kinenInk,
                                                                              lineWidth: number == nil ? 1 : 2) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.kind.title)，\(item.captureDate ?? "日期未知")")
            .accessibilityValue(number.map { "已选，第 \($0) 项" } ?? "未选")
            .accessibilityAddTraits(number == nil ? [] : .isSelected)
            .overlay(alignment: .bottomTrailing) {
                Button("预览", systemImage: "eye") { previewItem = item }
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.kinenPaper, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
            Text(linked.contains(item.id) ? "已关联" : item.kind.title)
                .font(.caption2)
                .foregroundStyle(Color.kinenMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var review: some View {
        NavigationStack {
            List {
                ForEach(selection, id: \.self) { id in
                    if let item = library.snapshot.mediaByID[id] {
                        MediaRow(library: library, item: item)
                    } else {
                        Label("缺失媒体", systemImage: "photo")
                    }
                }
                .onDelete { selection.remove(atOffsets: $0) }
                .onMove { selection.move(fromOffsets: $0, toOffset: $1) }
            }
            .kinenListStyle()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("已选媒体")
            .toolbar { Button("返回") { reviewing = false } }
        }
    }

    private func toggle(_ id: UUID) {
        if let index = selection.firstIndex(of: id) { selection.remove(at: index) }
        else { selection.append(id) }
    }

    private nonisolated static func filter(_ snapshot: LibrarySnapshot, request: Request) -> ResultSet {
        let search = MediaSearch(snapshot: snapshot)
        let query = LibraryQuery(request.query)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = request.zone
        formatter.dateFormat = "yyyy-MM-dd"
        let useCapture = request.basis == .capture
        let lower = request.range.map { formatter.string(from: $0.lowerBound) }
        let upper = request.range.map { formatter.string(from: $0.upperBound) }
        var months = Set<String>()
        var rows: [(day: String, month: String, media: LibraryMedia)] = []
        for item in snapshot.media {
            if Task.isCancelled { return ResultSet() }
            let day = (useCapture ? item.captureDate : formatter.string(from: item.createdAt)) ?? ""
            let month = String(day.prefix(7))
            months.insert(month)
            guard request.kind == nil || item.kind == request.kind else { continue }
            guard request.period == nil || request.period == month else { continue }
            if let lower, let upper, day < lower || day > upper { continue }
            switch request.subject {
            case .all: break
            case .member(let id): if !item.memberIds.contains(id) { continue }
            case .group(let id): if item.groupId != id { continue }
            case .untagged: if !item.memberIds.isEmpty || item.groupId != nil { continue }
            }
            if search.matches(item, query: query) { rows.append((day, month, item)) }
        }
        rows.sort { ($0.day, $0.media.createdAt) > ($1.day, $1.media.createdAt) }
        let groups = Dictionary(grouping: rows) { request.groupsByMonth ? $0.month : "" }
            .mapValues { $0.map(\.media) }
        return ResultSet(groups: groups, periods: months.sorted(by: >))
    }

    private func periodLabel(_ key: String) -> String { key.isEmpty ? "日期未知" : key }
}

struct NoteMediaThumbnail: View {
    let library: AppLibrary
    let item: LibraryMedia

    var body: some View {
        if item.kind == .video {
            VideoTile(store: library.store, item: item)
        } else {
            AssetImage(store: library.store, item: item, maxPixels: 330, icon: "photo",
                       fillsFrame: item.kind != .cheki, missingLabel: "附件缺失")
                .padding(item.kind == .cheki ? 4 : 0)
                .clipped()
        }
    }
}
