import AVKit
import Charts
import CoreImage
import ImageIO
import KinenCore
import PhotosUI
import UIKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: AppLibrary
    @State private var selection: Page = .home
    @State private var addingMedia = false
    @State private var collectionSearch = ""
    @State private var collectionViewID = UUID()
    @State private var homeSearch = ""
    @State private var homeMatches = SearchResults()
    @State private var collectionMatches = SearchResults()
    @State private var collectionSubject: ChekiSubject?
    @State private var collectionDate = CollectionDate.all
    @State private var customCollectionDate = Date.now
    @State private var pendingCollectionDate = Date.now
    @State private var pickingCollectionDate = false

    private enum CollectionDate: String, CaseIterable, Sendable {
        case all = "全部日期"
        case week = "最近 7 天"
        case month = "本月"
        case unknown = "日期未知"
        case custom = "指定日期"
    }

    private struct CollectionRequest: Equatable, Sendable {
        let search: LibrarySearchRequest
        let subject: ChekiSubject?
        let date: CollectionDate
        let range: ClosedRange<String>?
    }

    @State private var shownCollectionRequest: CollectionRequest?
    @State private var filteredCollection: [LibraryMedia] = []

    private struct SearchResults: Sendable {
        var request: LibrarySearchRequest?
        var entries: [LibraryEntry] = []
        var members: [Member] = []
        var groups: [IdolGroup] = []
        var media: [LibraryMedia] = []
    }
    @State private var homeDraft: LibraryEntry?
    @State private var scanImmediately = false

    private enum Page: Hashable {
        case home, journal, collection, settings
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                NavigationStack { home }
                    .id(library.store.root)
                    .toolbar(.hidden, for: .tabBar).tag(Page.home)
                NavigationStack { JournalList(library: library) }
                    .id(library.store.root)
                    .toolbar(.hidden, for: .tabBar).tag(Page.journal)
                NavigationStack { collection }
                    .id(library.store.root)
                    .id(collectionViewID)
                    .toolbar(.hidden, for: .tabBar).tag(Page.collection)
                NavigationStack { MemberSettings(library: library) }
                    .toolbar(.hidden, for: .tabBar).tag(Page.settings)
            }
            .frame(maxHeight: .infinity)
            navigationBar.fixedSize(horizontal: false, vertical: true)
        }
        .tint(.kinenInk)
        .sheet(isPresented: $addingMedia) {
            MediaImportView(library: library, startScanning: scanImmediately, onShowCollection: {
                collectionSearch = ""
                clearCollectionFilters()
                collectionViewID = UUID()
                selection = .collection
            })
        }
        .sheet(item: $homeDraft) { JournalEditor(library: library, entry: $0) }
        .task(id: LibrarySearchRequest(revision: library.snapshotVersion, text: homeSearch)) {
            if let matches = await search(text: homeSearch, chekiOnly: false) { homeMatches = matches }
        }
        .task(id: LibrarySearchRequest(revision: library.snapshotVersion, text: collectionSearch)) {
            if let matches = await search(text: collectionSearch, chekiOnly: true) { collectionMatches = matches }
        }
        .onChange(of: library.store.root) { _, _ in
            homeSearch = ""
            collectionSearch = ""
            clearCollectionFilters()
        }
        .alert("操作失败", isPresented: Binding(
            get: { library.error != nil },
            set: { if !$0 { library.error = nil } }
        )) {
            Button("好") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 0) {
            destination(.home, "首页", icon: "house")
            destination(.journal, "笔记", icon: "book")
            Button { openMedia() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(Color.kinenOnInk)
                        .background(Color.kinenInk, in: Circle())
                    Text("添加").font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .accessibilityLabel("添加媒体")
            destination(.collection, "收藏", icon: "heart")
            destination(.settings, "设置", icon: "gearshape")
        }
        .foregroundStyle(Color.kinenInk)
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            Color.kinenPaper.ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(Color.kinenLine).frame(height: 1) }
        }
    }

    private func destination(_ page: Page, _ title: String, icon: String) -> some View {
        Button { selection = page } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: selection == page ? .semibold : .regular))
                    .frame(width: 40, height: 28)
                    .background(selection == page ? Color.kinenCanvas : .clear, in: Capsule())
                Text(title)
                    .font(.caption2.weight(selection == page ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
            .foregroundStyle(selection == page ? Color.kinenInk : Color.kinenMuted)
        }
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }

    private func openMedia(scan: Bool = false) {
        scanImmediately = scan
        addingMedia = true
    }

    private var home: some View {
        let snapshot = library.snapshot
        let query = LibraryQuery(homeSearch)
        return Group {
            if query.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let entry = snapshot.entries.first {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("最近笔记").font(.title3.weight(.semibold))
                                    Spacer()
                                    Button("查看全部") { selection = .journal }.font(.subheadline)
                                }
                                NavigationLink {
                                    JournalDetail(library: library, id: entry.id)
                                } label: {
                                    featured(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let draft = library.drafts.first {
                            Button {
                                homeDraft = draft.entry
                            } label: {
                                HStack {
                                    Label("继续写草稿", systemImage: "pencil")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                .padding(12)
                                .frame(minHeight: 44)
                                .kinenCard(radius: 14)
                            }
                            .buttonStyle(.plain)
                        } else if snapshot.entries.isEmpty && snapshot.media.isEmpty {
                            homeEmpty
                        }

                        if !snapshot.media.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("最近媒体").font(.title3.weight(.semibold))
                                    Spacer()
                                    NavigationLink("查看全部") {
                                        MediaBrowser(library: library)
                                    }
                                    .font(.subheadline)
                                }
                                MediaGrid(library: library, items: Array(snapshot.media.prefix(6)))
                            }
                        }

                        if !snapshot.members.isEmpty || snapshot.chekiCount() > 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("成员收藏").font(.title3.weight(.semibold))
                                    Spacer()
                                    Button("查看全部") { selection = .collection }.font(.subheadline)
                                }
                                if snapshot.members.isEmpty {
                                    subjectLink("全部拍立得", subject: nil).padding(16)
                                } else {
                                    ForEach(snapshot.members.prefix(3)) { member in
                                        memberLink(member)
                                    }
                                    .padding(12)
                                    .kinenCard(radius: 16)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.kinenCanvas)
            } else {
                homeResults
            }
        }
        .navigationTitle("記念撮影")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image("BrandMark").resizable().frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Text("記念撮影").font(.title3.weight(.semibold))
                }
                .accessibilityAddTraits(.isHeader)
            }
        }
        .searchable(text: $homeSearch, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索笔记、成员或媒体")
    }

    private var homeEmpty: some View {
        VStack(spacing: 14) {
            Text("从一张拍立得开始").font(.title2.weight(.semibold))
            Button { openMedia(scan: true) } label: {
                Label("扫描第一张拍立得", systemImage: "camera.viewfinder")
                    .kinenPrimaryButton()
            }
            .buttonStyle(.plain)
            Button("写一段回忆") { homeDraft = LibraryEntry() }
                .frame(minHeight: 44)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .kinenCard()
    }

    private func featured(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NoteCoverImage(library: library, entry: entry, height: 210)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.kind.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.kinenCanvas, in: Capsule())
                Text(entry.title).font(.title2.weight(.semibold)).lineLimit(2)
                if !entry.mediaIds.contains(where: { id in
                    library.snapshot.mediaByID[id].map { $0.kind != .video } ?? false
                }), let excerpt = noteExcerpt(entry.body) {
                    Text(excerpt).font(.subheadline).lineLimit(2).foregroundStyle(Color.kinenMuted)
                }
                Text(entry.startDate).font(.subheadline.monospacedDigit()).foregroundStyle(Color.kinenMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .kinenCard()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private func noteExcerpt(_ markdown: String) -> String? {
        NoteMarkdownBlock.parse(String(markdown.prefix(500))).lazy.compactMap { block in
            switch block {
            case .paragraph(let text), .heading(_, let text), .quote(let text), .listItem(_, let text): text
            default: nil
            }
        }.first
    }

    private func search(text: String, chekiOnly: Bool) async -> SearchResults? {
        let query = LibraryQuery(text)
        guard !query.isEmpty else { return SearchResults() }
        let snapshot = library.snapshot
        let request = LibrarySearchRequest(revision: library.snapshotVersion, text: text)
        do { try await Task.sleep(for: .milliseconds(140)) }
        catch { return nil }
        let found = await LibraryWork.run {
            let search = MediaSearch(snapshot: snapshot)
            return SearchResults(request: request,
                entries: chekiOnly ? [] : snapshot.entries.filter { !Task.isCancelled && query.matches($0) },
                members: snapshot.members.filter { !Task.isCancelled && query.matches([$0.name] + $0.aliases) },
                groups: snapshot.groups.filter { !Task.isCancelled && query.matches([$0.name]) },
                media: (chekiOnly ? snapshot.chekiMedia : snapshot.media).filter {
                    !Task.isCancelled && search.matches($0, query: query)
                })
        }
        return Task.isCancelled ? nil : found
    }

    private var homeResults: some View {
        let request = LibrarySearchRequest(revision: library.snapshotVersion, text: homeSearch)
        let pending = homeMatches.request != request
        let search = MediaSearch(snapshot: library.snapshot)
        let matches = pending ? SearchResults() : homeMatches
        let (entries, members, groups, media) = (matches.entries, matches.members, matches.groups, matches.media)
        return List {
            if !entries.isEmpty {
                Section("笔记") {
                    ForEach(entries) { entry in
                        NavigationLink { JournalDetail(library: library, id: entry.id) } label: { JournalRow(entry: entry) }
                    }
                }
            }
            if !members.isEmpty { Section("成员") { ForEach(members) { memberLink($0) } } }
            if !groups.isEmpty { Section("团体") { ForEach(groups) { subjectLink($0.name, subject: .group($0.id)) } } }
            if !media.isEmpty { Section("媒体") { ForEach(media) { mediaLink($0, names: search.names(for: $0)) } } }
        }
        .kinenListStyle()
        .overlay {
            if pending {
                ProgressView().accessibilityLabel("正在搜索")
            } else if entries.isEmpty && members.isEmpty && groups.isEmpty && media.isEmpty {
                ContentUnavailableView.search(text: homeSearch).allowsHitTesting(false)
            }
        }
    }

    private func memberLink(_ member: Member) -> some View {
        NavigationLink {
            SubjectCollection(library: library, title: member.name, subject: .member(member.id))
        } label: {
            LabeledContent {
                Text("\(library.snapshot.chekis(for: .member(member.id)).count) 张")
                    .foregroundStyle(Color.kinenMuted)
                    .monospacedDigit()
            } label: {
                MemberProfileRow(member: member)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var collection: some View {
        let snapshot = library.snapshot
        let query = LibraryQuery(collectionSearch)
        let searchRequest = LibrarySearchRequest(revision: library.snapshotVersion, text: collectionSearch)
        let searching = !query.isEmpty && collectionMatches.request != searchRequest
        let request = CollectionRequest(search: searchRequest, subject: collectionSubject,
                                        date: collectionDate, range: collectionRange)
        let dateFiltered = collectionDate != .all
        let filtering = dateFiltered && shownCollectionRequest != request
        let photos = query.isEmpty
            ? collectionSubject.map { snapshot.chekis(for: $0) } ?? snapshot.chekiMedia
            : searching ? [] : collectionSubject == nil ? collectionMatches.media
            : collectionMatches.media.filter { Self.matchesCollectionSubject($0, subject: request.subject) }
        let visible = searching || filtering ? [] : dateFiltered ? filteredCollection : photos
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                collectionFilters
                if searching || filtering {
                    ProgressView("正在筛选…").frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    if !visible.isEmpty {
                        Text(query.isEmpty && collectionSubject == nil && !dateFiltered
                             ? "最近拍立得 · \(visible.count) 张" : "拍立得 · \(visible.count) 张")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        MediaGrid(library: library, items: visible)
                    }
                    if !query.isEmpty {
                        if !collectionMatches.members.isEmpty {
                            Text("成员").font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(collectionMatches.members) { member in
                                memberLink(member).padding(12).kinenCard(radius: 14)
                            }
                        }
                        if !collectionMatches.groups.isEmpty {
                            Text("团体").font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(collectionMatches.groups) { group in
                                subjectLink(group.name, subject: .group(group.id)).padding(12).kinenCard(radius: 14)
                            }
                        }
                    }
                    if visible.isEmpty && (query.isEmpty ||
                        (collectionMatches.members.isEmpty && collectionMatches.groups.isEmpty)) {
                        ContentUnavailableView(
                            snapshot.chekiMedia.isEmpty ? "还没有拍立得" : "没有符合条件的拍立得",
                            systemImage: "photo.on.rectangle",
                            description: Text(snapshot.chekiMedia.isEmpty ? "点底栏的「添加」保存第一张。" : "可以清除筛选或更换搜索词。")
                        )
                    }
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
        }
        .background(Color.kinenCanvas)
        .navigationTitle("收藏")
        .searchable(text: $collectionSearch, prompt: "搜索成员、团体、日期或备注")
        .toolbar {
            NavigationLink {
                SubjectCollection(library: library, title: collectionSubject == nil ? "收藏统计" : collectionSubjectName,
                                  subject: collectionSubject)
            } label: {
                Label("统计", systemImage: "chart.bar.xaxis")
            }
        }
        .sheet(isPresented: $pickingCollectionDate) { collectionDatePicker }
        .task(id: CollectionTask(request: request, searching: searching)) {
            guard dateFiltered, !searching else { return }
            let found = await LibraryWork.run {
                photos.filter { item in
                    guard !Task.isCancelled else { return false }
                    if request.date == .unknown { return item.captureDate?.isEmpty != false }
                    guard let date = item.captureDate, let range = request.range else { return false }
                    return range.contains(date)
                }
            }
            if !Task.isCancelled {
                filteredCollection = found
                shownCollectionRequest = request
            }
        }
    }

    private struct CollectionTask: Equatable {
        let request: CollectionRequest
        let searching: Bool
    }

    private static func matchesCollectionSubject(_ item: LibraryMedia, subject: ChekiSubject?) -> Bool {
        switch subject {
        case .member(let id): item.memberIds.contains(id)
        case .group(let id): item.groupId == id
        case nil: true
        }
    }

    private var collectionSubjectName: String {
        switch collectionSubject {
        case .member(let id): library.snapshot.membersByID[id]?.name ?? "成员"
        case .group(let id): library.snapshot.groupsByID[id]?.name ?? "团体"
        case nil: "成员或团体"
        }
    }

    private var collectionRange: ClosedRange<String>? {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date.now
        switch collectionDate {
        case .all, .unknown: return nil
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return LocalDay.string(from: start)...LocalDay.string(from: today)
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: today),
                  let last = calendar.date(byAdding: .day, value: -1, to: month.end) else { return nil }
            return LocalDay.string(from: month.start)...LocalDay.string(from: last)
        case .custom:
            let chosen = LocalDay.string(from: customCollectionDate)
            return chosen...chosen
        }
    }

    private var collectionFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { collectionFilterActions }
            VStack(alignment: .leading, spacing: 4) { collectionFilterActions }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var collectionFilterActions: some View {
        Menu {
            Picker("成员或团体", selection: $collectionSubject) {
                Text("全部").tag(nil as ChekiSubject?)
                Section("成员") {
                    ForEach(library.snapshot.members) { member in
                        Text(member.name).tag(Optional(ChekiSubject.member(member.id)))
                    }
                }
                Section("团体") {
                    ForEach(library.snapshot.groups) { group in
                        Text(group.name).tag(Optional(ChekiSubject.group(group.id)))
                    }
                }
            }
        } label: {
            collectionChip(collectionSubjectName, icon: "person.2", active: collectionSubject != nil)
        }
        Menu {
            ForEach(CollectionDate.allCases, id: \.self) { date in
                Button {
                    if date == .custom {
                        pendingCollectionDate = collectionDate == .custom ? customCollectionDate : .now
                        pickingCollectionDate = true
                    }
                    else { collectionDate = date }
                } label: {
                    if collectionDate == date { Label(date.rawValue, systemImage: "checkmark") }
                    else { Text(date.rawValue) }
                }
            }
        } label: {
            collectionChip(collectionDate == .custom ? LocalDay.string(from: customCollectionDate)
                           : collectionDate == .all ? "时间" : collectionDate.rawValue,
                           icon: "calendar", active: collectionDate != .all)
        }
        if collectionSubject != nil || collectionDate != .all {
            Button("清除", action: clearCollectionFilters).frame(minHeight: 44)
        }
    }

    private var collectionDatePicker: some View {
        NavigationStack {
            Form {
                DatePicker("拍摄日期", selection: $pendingCollectionDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            .kinenListStyle()
            .navigationTitle("指定日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pickingCollectionDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        customCollectionDate = pendingCollectionDate
                        collectionDate = .custom
                        pickingCollectionDate = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func collectionChip(_ title: String, icon: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(active ? Color.kinenOnInk : Color.kinenInk)
            .background(active ? Color.kinenInk : Color.kinenPaper, in: Capsule())
    }

    private func clearCollectionFilters() {
        collectionSubject = nil
        collectionDate = .all
    }

    private func subjectLink(_ name: String, subject: ChekiSubject?) -> some View {
        let count = subject.map { library.snapshot.chekis(for: $0).count } ?? library.snapshot.chekiCount()
        return NavigationLink {
            SubjectCollection(library: library, title: name, subject: subject)
        } label: {
            LabeledContent(name, value: "\(count) 张")
        }
    }

    private func mediaLink(_ item: LibraryMedia, names: [String] = []) -> some View {
        NavigationLink {
            MediaDetail(library: library, item: item)
        } label: {
            MediaRow(library: library, item: item, names: names)
        }
    }
}

struct SubjectCollection: View {
    let library: AppLibrary
    let title: String
    let subject: ChekiSubject?

    @State private var basis = CollectionDateBasis.capture
    @State private var preferredYear: Int?
    @State private var showsCalendar = true
    @State private var showsTrend = true
    @State private var selectedDayID: String?
    @State private var searchText = ""
    @State private var trend = CollectionDateBasis.capture.trend(for: [])
    @State private var loadedTrend: TrendRequest?
    @State private var loadedPhotos: PhotoRequest?
    @State private var filteredPhotos: [LibraryMedia] = []

    private struct TrendRequest: Equatable, Sendable {
        let revision: Int
        let basis: CollectionDateBasis
        let zone: TimeZone
    }

    private struct PhotoRequest: Equatable {
        let trend: TrendRequest
        let day: String?
        let query: String
    }

    private var photos: [LibraryMedia] {
        if let subject { return library.snapshot.chekis(for: subject) }
        return library.snapshot.chekiMedia
    }

    var body: some View {
        let photos = photos
        let zone = TimeZone.current
        let request = TrendRequest(revision: library.snapshotVersion, basis: basis, zone: zone)
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: .now)
        let years = Set(trend.years + [currentYear]).sorted(by: >)
        let year = preferredYear.flatMap { years.contains($0) ? $0 : nil } ?? trend.years.first ?? currentYear
        let months = trend.months(in: year)
        let yearlyCount = months.reduce(0) { $0 + $1.count }
        let weeks = showsCalendar ? trend.weeks(in: year) : []
        let selectedDay = selectedDayID.flatMap { id in weeks.lazy.flatMap(\.days).compactMap { $0 }.first { $0.id == id } }
        let query = LibraryQuery(searchText)
        let photoRequest = PhotoRequest(trend: request, day: selectedDay?.id, query: searchText)
        let ordinaryView = query.isEmpty && selectedDay == nil
        let visiblePhotos = ordinaryView ? photos : loadedPhotos == photoRequest ? filteredPhotos : []
        List {
            if query.isEmpty {
                Section {
                    if case let .member(id) = subject,
                       let member = library.snapshot.membersByID[id] {
                        LabeledContent {
                            Text("\(photos.count) 张").font(.title3.monospacedDigit().weight(.semibold))
                        } label: {
                            MemberProfileRow(member: member)
                        }
                    } else {
                        LabeledContent("收藏总数", value: "\(photos.count) 张")
                    }
                }
                trendSection(trend, year: year, years: years, months: months, yearlyCount: yearlyCount,
                             weeks: weeks, selectedDay: selectedDay)
            }
            Section {
                if !ordinaryView && loadedPhotos != photoRequest {
                    ProgressView("正在筛选…")
                } else if visiblePhotos.isEmpty {
                    Text(!query.isEmpty ? "没有符合搜索的拍立得" :
                            selectedDay == nil ? "还没有拍立得" : "这一天没有拍立得")
                        .foregroundStyle(.secondary)
                }
                if !visiblePhotos.isEmpty {
                    MediaGrid(library: library, items: visiblePhotos)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } header: {
                if let selectedDay {
                    HStack {
                        Text("\(selectedDay.id) · \(visiblePhotos.count) 张")
                        Spacer()
                        Button("显示全部日期") { selectedDayID = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                    }
                } else {
                    Text("拍立得 · \(visiblePhotos.count) 张")
                }
            }
        }
        .task(id: request) {
            let updated = await LibraryWork.run { request.basis.trend(for: photos, timeZone: request.zone) }
            if !Task.isCancelled {
                trend = updated
                loadedTrend = request
            }
        }
        .task(id: photoRequest) {
            guard !ordinaryView else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(140)) }
                catch { return }
            }
            let search = MediaSearch(snapshot: library.snapshot)
            let updated = await LibraryWork.run {
                let attributed = selectedDay.map { request.basis.photos(on: $0, from: photos, timeZone: zone) } ?? photos
                return attributed.filter { !Task.isCancelled && search.matches($0, query: query) }
            }
            if !Task.isCancelled {
                filteredPhotos = updated
                loadedPhotos = photoRequest
            }
        }
        .onChange(of: year) { _, _ in selectedDayID = nil }
        .onChange(of: basis) { _, _ in selectedDayID = nil }
        .onChange(of: showsCalendar) { _, _ in selectedDayID = nil }
        .kinenListStyle()
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "搜索拍立得")
    }

    private func trendSection(_ trend: CollectionTrend, year: Int, years: [Int], months: [CollectionMonth],
                              yearlyCount: Int, weeks: [CollectionWeek], selectedDay: CollectionDay?) -> some View {
        Section {
            DisclosureGroup("收藏趋势", isExpanded: $showsTrend) {
                if loadedTrend == nil { ProgressView("正在统计…") }
                Picker("统计日期", selection: $basis) {
                    Text("按拍摄日期").tag(CollectionDateBasis.capture)
                    Text("按入库日期").tag(CollectionDateBasis.added)
                }
                .pickerStyle(.segmented)
                Picker("年份", selection: Binding(
                    get: { year },
                    set: { preferredYear = $0 }
                )) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                LabeledContent("\(String(year)) 年合计", value: "\(yearlyCount) 张")
                Picker("图表类型", selection: $showsCalendar) {
                    Text("每日格子").tag(true)
                    Text("月度柱状").tag(false)
                }
                .pickerStyle(.segmented)
                if showsCalendar {
                    CollectionHeatmap(weeks: weeks, selected: selectedDay, selectedDayID: $selectedDayID)
                        .id("\(year)-\(basis.rawValue)")
                    DatePicker("按日期查看", selection: Binding(
                        get: { selectedDay.flatMap { LocalDay.date(from: $0.id) } ??
                            LocalDay.date(from: "\(year)-01-01") ?? .now },
                        set: { selectedDayID = LocalDay.string(from: $0) }
                    ), in: (LocalDay.date(from: "\(year)-01-01") ?? .distantPast)...(LocalDay.date(from: "\(year)-12-31") ?? .distantFuture),
                       displayedComponents: .date)
                        .font(.subheadline)
                } else if yearlyCount > 0 {
                    trendChart(months)
                } else {
                    Text("这一年没有记录").foregroundStyle(.secondary)
                }
                if yearlyCount > 0 {
                    DisclosureGroup("逐月明细") {
                        ForEach(months) { month in
                            LabeledContent("\(month.number) 月", value: "\(month.count) 张")
                        }
                    }
                }
                if trend.unknownCount > 0 {
                    LabeledContent("拍摄日期未知", value: "\(trend.unknownCount) 张")
                }
            }
        }
    }

    private func trendChart(_ months: [CollectionMonth]) -> some View {
        Chart(months) { month in
            BarMark(x: .value("月份", month.number), y: .value("张数", month.count))
                .foregroundStyle(Color.primary)
                .cornerRadius(3)
                .accessibilityLabel("\(month.number) 月")
                .accessibilityValue("\(month.count) 张")
        }
        .chartXScale(domain: 0.5...12.5)
        .chartXAxis {
            AxisMarks(values: [1, 4, 7, 10, 12]) { axis in
                AxisValueLabel {
                    if let month = axis.as(Int.self) { Text("\(month) 月") }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 160)
        .accessibilityLabel("拍立得月度趋势")
    }
}

private struct CollectionHeatmap: View {
    let weeks: [CollectionWeek]
    let selected: CollectionDay?
    @Binding var selectedDayID: String?
    @ScaledMetric(relativeTo: .caption) private var cellSize = 15.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .bottom, spacing: 3) {
                        weekdays
                        ForEach(weeks) { week in
                            VStack(spacing: 3) {
                                ForEach(week.days.indices, id: \.self) { index in
                                    if let day = week.days[index] {
                                        dayCell(day)
                                    } else {
                                        Color.clear.frame(width: cellSize, height: cellSize)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .id(week.id)
                            .padding(.top, cellSize + 4)
                            .overlay(alignment: .topLeading) {
                                if let month = week.startingMonth {
                                    Text("\(month) 月")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.trailing, 14)
                }
                .task {
                    let recent = weeks.last { $0.days.contains { ($0?.count ?? 0) > 0 } }
                    if let id = recent?.id { reader.scrollTo(id, anchor: .trailing) }
                }
            }

            ViewThatFits(in: .horizontal) {
                legend
                Text("每格为 0、1、2–3、4–7 或 8 张以上。")
            }
            .font(.caption2)
            .foregroundStyle(Color.kinenMuted)
            .accessibilityLabel("色阶分别代表零张、一张、两到三张、四到七张、八张以上")

            if let selected {
                LabeledContent(selected.id, value: "\(selected.count) 张")
                    .font(.subheadline)
                    .monospacedDigit()
            } else {
                Text("横向滑动查看全年，点格子筛选当天的拍立得。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            let levels = [(0, "0"), (1, "1"), (2, "2–3"), (4, "4–7"), (8, "8+")]
            ForEach(levels, id: \.0) { count, label in
                HStack(spacing: 3) {
                    tile(count).frame(width: 10, height: 10)
                    Text(label)
                }
            }
        }
    }

    private var weekdays: some View {
        let labels = ["", "一", "", "三", "", "五", ""]
        return VStack(alignment: .trailing, spacing: 3) {
            ForEach(labels.indices, id: \.self) { index in
                Text(labels[index])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: cellSize)
            }
        }
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }

    private func dayCell(_ day: CollectionDay) -> some View {
        Button {
            selectedDayID = selectedDayID == day.id ? nil : day.id
        } label: {
            tile(day.count)
                .overlay {
                    if selected?.id == day.id {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary, lineWidth: 1.5)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1)
                                    .padding(1.5)
                            }
                    }
                }
                .frame(width: cellSize, height: cellSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.id)
        .accessibilityValue("\(day.count) 张")
        .accessibilityAddTraits(selected?.id == day.id ? .isSelected : [])
    }

    private func tile(_ count: Int) -> some View {
        let opacity: Double
        switch count {
        case 0: opacity = 0.09
        case 1: opacity = 0.30
        case 2...3: opacity = 0.50
        case 4...7: opacity = 0.73
        default: opacity = 0.95
        }
        return RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(opacity))
    }
}

struct MemberSettings: View {
    let library: AppLibrary
    @State private var switching = false

    var body: some View {
        Form {
            Section("资料库") {
                Picker("当前资料库", selection: Binding<UUID?>(
                    get: { library.activeLibraryID },
                    set: { id in
                        switching = true
                        Task {
                            defer { switching = false }
                            do { try await library.switchLibrary(to: id) }
                            catch { library.error = error.localizedDescription }
                        }
                    }
                )) {
                    ForEach(library.libraryChoices) { choice in Text(choice.name).tag(choice.id) }
                }
                if switching { ProgressView("正在打开资料库…") }
            }
            Section {
                NavigationLink { MemberDirectorySettings(library: library) } label: {
                    Label("成员与团体", systemImage: "person.2")
                }
                NavigationLink { LocalBackupSettings(library: library) } label: {
                    Label("备份与同步", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink { FeedbackSettings() } label: {
                    Label("反馈", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .disabled(switching)
        .kinenListStyle()
        .navigationTitle("设置")
    }
}

private struct MemberDirectorySettings: View {
    let library: AppLibrary
    @State private var creatingMember = false
    @State private var editingGroupName = false
    @State private var editingGroup: IdolGroup?
    @State private var groupName = ""
    @State private var editingMember: Member?
    @State private var searchText = ""
    @State private var showsArchived = false

    var body: some View {
        let query = LibraryQuery(searchText)
        let matching = library.snapshot.members.filter { query.matches([$0.name] + $0.aliases) }
        let active = matching.filter { !$0.archived }
        let archived = matching.filter(\.archived)
        let groups = library.snapshot.groups.filter { query.matches([$0.name]) }
        return Form {
            if !active.isEmpty || query.isEmpty {
                Section("成员") {
                    ForEach(active) { member in memberRow(member) }
                    if query.isEmpty {
                        Button("添加成员", systemImage: "person.badge.plus") { creatingMember = true }
                    }
                }
            }
            if !groups.isEmpty || query.isEmpty {
                Section("团体") {
                    ForEach(groups) { group in
                        Button {
                            editingGroup = group
                            groupName = group.name
                            editingGroupName = true
                        } label: {
                            HStack {
                                Label(group.name, systemImage: "person.3")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if query.isEmpty {
                        Button("添加团体", systemImage: "person.3") {
                            editingGroup = nil
                            groupName = ""
                            editingGroupName = true
                        }
                    }
                }
            }
            if !archived.isEmpty {
                Section {
                    if query.isEmpty {
                        DisclosureGroup("已归档 · \(archived.count) 位", isExpanded: $showsArchived) {
                            ForEach(archived) { member in memberRow(member) }
                        }
                    } else {
                        ForEach(archived) { member in memberRow(member) }
                    }
                } header: {
                    if !query.isEmpty { Text("已归档") }
                }
            }
            if !query.isEmpty && matching.isEmpty && groups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .kinenListStyle()
        .navigationTitle("成员与团体")
        .searchable(text: $searchText, prompt: "搜索姓名、别名或团体")
        .alert(editingGroup == nil ? "添加团体" : "编辑团体", isPresented: $editingGroupName) {
            TextField("团体名称", text: $groupName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = groupName
                let id = editingGroup?.id
                Task { _ = await library.perform { _ = try await library.store.saveGroup(id: id, name: name) } }
            }
            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $creatingMember) { MemberEditor(library: library) }
        .sheet(item: $editingMember) { member in MemberEditor(library: library, member: member) }
    }

    private func memberRow(_ member: Member) -> some View {
        Button { editingMember = member } label: {
            HStack {
                MemberProfileRow(member: member)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FeedbackSettings: View {
    var body: some View {
        Form {
            Section {
                if let url = Self.feedbackURL(isSuggestion: false) {
                    Link(destination: url) { Label("报告问题", systemImage: "exclamationmark.bubble") }
                }
                if let url = Self.feedbackURL(isSuggestion: true) {
                    Link(destination: url) { Label("提出建议", systemImage: "lightbulb") }
                }
                if let url = URL(string: "https://github.com/vacabun/kinen-satsuei/issues") {
                    Link(destination: url) { Label("查看 GitHub Issues", systemImage: "arrow.up.right.square") }
                }
            } header: {
                Text("反馈")
            } footer: {
                Text("在 GitHub 登录并确认后提交。公开 Issue 中请避免填写私密资料。")
            }
        }
        .kinenListStyle()
        .navigationTitle("反馈")
    }

    private static func feedbackURL(isSuggestion: Bool) -> URL? {
        var components = URLComponents(string: "https://github.com/vacabun/kinen-satsuei/issues/new")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let body = isSuggestion
            ? "### 想改进什么\n\n### 在什么情况下会用到\n\n"
            : "### 遇到的问题\n\n### 复现步骤\n1. \n2. \n\n### 预期结果\n\n### 实际结果\n\n"
        components?.queryItems = [
            URLQueryItem(name: "title", value: isSuggestion ? "[建议] " : "[问题] "),
            URLQueryItem(name: "body", value: body + "### 应用版本\niOS 版 \(version)（\(build)）")
        ]
        return components?.url
    }

}

private struct LocalBackupSettings: View {
    let library: AppLibrary
    @State private var operation = BackupOperation.export
    @State private var choosingFolder = false
    @State private var working = false
    @State private var backupMessage: String?
    @State private var restoredID: UUID?
    @State private var pendingRestore: (folder: URL, title: String)?
    @State private var showsStorage = false

    private enum BackupOperation { case export, restore }

    var body: some View {
        Form {
            Section("文件夹备份") {
                Button("备份到文件夹", systemImage: "square.and.arrow.up") { choose(.export) }
                Button("从备份恢复", systemImage: "square.and.arrow.down") { choose(.restore) }
                if working { ProgressView("正在处理资料库…") }
            }
            Section {
                NavigationLink { GitSyncSettings(library: library) } label: {
                    Label("Git 同步", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("平时可以直接保存到本机，需要跨设备使用时再设置 Git 同步。")
            }
            Section {
                DisclosureGroup("本机存储", isExpanded: $showsStorage) {
                    if showsStorage { LibraryStorageSummary(library: library) }
                }
            }
        }
        .disabled(working)
        .kinenListStyle()
        .navigationTitle("备份与同步")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): process(folder: folder)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .alert("资料库备份", isPresented: Binding(
            get: { backupMessage != nil },
            set: { if !$0 { backupMessage = nil; restoredID = nil; pendingRestore = nil } }
        )) {
            if let pendingRestore {
                Button("恢复为独立资料库") { restore(folder: pendingRestore.folder, title: pendingRestore.title) }
                Button("取消", role: .cancel) {}
            } else if let id = restoredID {
                Button("打开恢复的资料库") { switchLibrary(to: id) }
                Button("留在当前资料库", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(backupMessage ?? "")
        }
    }

    private func choose(_ action: BackupOperation) {
        operation = action
        restoredID = nil
        choosingFolder = true
    }

    private func process(folder: URL) {
        working = true
        let operation = operation
        Task {
            let access = folder.startAccessingSecurityScopedResource()
            defer {
                if access { folder.stopAccessingSecurityScopedResource() }
                working = false
            }
            do {
                switch operation {
                case .export:
                    let suffix = UUID().uuidString.prefix(6).lowercased()
                    let name = "記念撮影-\(LocalDay.today())-\(suffix)"
                    let summary = try await library.store.exportBackup(to: folder.appending(path: name))
                    backupMessage = "\(name)\n\(description(of: summary))"
                case .restore:
                    let preview = try await LibraryBackup.preview(from: folder)
                    pendingRestore = (folder, preview.title)
                    backupMessage = "\(preview.title)\n\(description(of: preview.summary))"
                }
            } catch {
                library.error = error.localizedDescription
            }
        }
    }

    private func restore(folder: URL, title: String) {
        working = true
        pendingRestore = nil
        backupMessage = nil
        Task {
            let access = folder.startAccessingSecurityScopedResource()
            defer {
                if access { folder.stopAccessingSecurityScopedResource() }
                working = false
            }
            do {
                let result = try await library.importBackup(from: folder, name: title)
                restoredID = result.id
                backupMessage = "已恢复到独立资料库。\n\(description(of: result.summary))"
            } catch {
                library.error = error.localizedDescription
            }
        }
    }

    private func switchLibrary(to id: UUID?) {
        working = true
        Task {
            defer { working = false }
            do { try await library.switchLibrary(to: id) }
            catch { library.error = error.localizedDescription }
        }
    }

    private func description(of summary: BackupSummary) -> String {
        let counts = "\(summary.notes) 篇笔记、\(summary.media) 条媒体记录"
        return summary.missingAssets > 0 ? "\(counts)，\(summary.missingAssets) 项媒体文件缺失。" : counts
    }
}

private struct LibraryStorageSummary: View {
    let library: AppLibrary
    @State private var bytes: Int64?

    var body: some View {
        Group {
            if let bytes {
                LabeledContent("媒体文件", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            } else { ProgressView("正在计算…") }
        }
        .task(id: library.snapshotVersion) {
            let store = library.store
            let snapshot = library.snapshot
            let result = await LibraryWork.run {
                let urls = Set(snapshot.media.flatMap(\.assets).map { store.assetURL($0) })
                return urls.reduce(into: Int64(0)) { bytes, url in
                    if !Task.isCancelled, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        bytes += Int64(size)
                    }
                }
            }
            if !Task.isCancelled { bytes = result }
        }
    }
}

private struct MediaBrowser: View {
    let library: AppLibrary
    @State private var searchText = ""
    @State private var preview: PhotoPreview?
    @State private var pendingDetail: UUID?
    @State private var detailID: UUID?
    @State private var shareRequest: ShareRequest?

    private struct PhotoPreview: Identifiable {
        let id: UUID
        let photos: [LibraryMedia]
    }
    @State private var kind: MediaKind?
    @AppStorage("mediaBrowserGroupsByDate") private var groupsByDate = false
    @State private var results = Results()

    private struct DayGroup: Identifiable, Sendable {
        let id: String
        let items: [LibraryMedia]
    }

    private struct Results: Sendable {
        var items: [LibraryMedia] = []
        var days: [DayGroup] = []
    }
    @State private var completedRequest: Request?

    private struct Request: Equatable {
        let search: LibrarySearchRequest
        let kind: MediaKind?
        let groupsByDate: Bool
    }

    var body: some View {
        let snapshot = library.snapshot
        let query = LibraryQuery(searchText)
        let request = Request(search: LibrarySearchRequest(revision: library.snapshotVersion, text: searchText),
                              kind: kind, groupsByDate: groupsByDate)
        let browsing = query.isEmpty && kind == nil
        let pending = (!browsing || groupsByDate) && completedRequest != request
        let items = browsing && !groupsByDate ? snapshot.media : results.items

        ScrollView {
            if pending {
                ProgressView().accessibilityLabel("正在查找媒体")
                    .frame(maxWidth: .infinity).padding(32)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("没有符合条件的媒体", systemImage: "photo.on.rectangle")
                } actions: {
                    if !browsing {
                        Button("清除筛选") {
                            searchText = ""
                            kind = nil
                        }
                    }
                }
            } else if groupsByDate {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(results.days) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.id.isEmpty ? "日期未知" : day.id)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .accessibilityAddTraits(.isHeader)
                            grid(items: day.items, browsingOrder: items)
                        }
                    }
                }
                .padding(16)
            } else {
                grid(items: items, browsingOrder: items).padding(16)
            }
        }
        .background(Color.kinenCanvas)
        .navigationTitle("全部媒体")
        .navigationDestination(item: $detailID) { id in
            if let item = library.snapshot.mediaByID[id] {
                MediaDetail(library: library, item: item, browsingOrder: items)
            } else {
                ContentUnavailableView("找不到媒体", systemImage: "photo")
            }
        }
        .fullScreenCover(item: $preview, onDismiss: {
            detailID = pendingDetail
            pendingDetail = nil
        }) { preview in
            SavedPhotoViewer(library: library, photos: preview.photos, initialID: preview.id) { id in
                pendingDetail = id
                self.preview = nil
            }
        }
        .modifier(MediaSharing(request: $shareRequest))
        .searchable(text: $searchText, prompt: "搜索成员、团体、日期或备注")
        .toolbar {
            Menu {
                Picker("浏览方式", selection: $groupsByDate) {
                    Text("最近添加").tag(false)
                    Text("按拍摄日期").tag(true)
                }
                Divider()
                Picker("媒体类型", selection: $kind) {
                    Text("全部类型").tag(nil as MediaKind?)
                    ForEach(MediaKind.allCases) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
            } label: {
                Label(kind?.title ?? "媒体排序与筛选",
                      systemImage: kind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        .task(id: request) {
            guard !browsing || request.groupsByDate else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(140)) }
                catch { return }
            }
            let matches = await LibraryWork.run {
                let search = MediaSearch(snapshot: snapshot)
                let items = snapshot.media.filter { item in
                    !Task.isCancelled && (request.kind == nil || item.kind == request.kind) &&
                        (query.isEmpty || search.matches(item, query: query))
                }
                guard request.groupsByDate, !Task.isCancelled else { return Results(items: items) }
                let days = Dictionary(grouping: items) { $0.captureDate ?? "" }
                let orderedDays = days.map { DayGroup(id: $0.key, items: $0.value) }.sorted { $0.id > $1.id }
                return Results(items: orderedDays.flatMap(\.items), days: orderedDays)
            }
            guard !Task.isCancelled else { return }
            results = matches
            completedRequest = request
        }
    }

    private func grid(items: [LibraryMedia], browsingOrder: [LibraryMedia]) -> some View {
        MediaGrid(library: library, items: items, openPhoto: { item in
            preview = PhotoPreview(id: item.id, photos: browsingOrder.filter { $0.kind != .video })
        }, openPhotoDetails: { item in
            detailID = item.id
        }, sharePhoto: { item in
            guard shareRequest == nil else { return }
            let asset = library.store.displayAsset(for: item)
            let name = asset.sha256 == item.enhanced?.sha256 ? "调整图"
                : asset.sha256 == item.corrected?.sha256 ? "校正图" : "照片"
            shareRequest = ShareRequest(asset: asset, store: library.store,
                                        name: name, quarterTurns: item.quarterTurns ?? 0)
        })
    }
}

struct MediaRow: View {
    let library: AppLibrary
    let item: LibraryMedia
    var names: [String] = []

    var body: some View {
        HStack {
            AssetImage(store: library.store, item: item, maxPixels: 180, icon: item.kind == .video ? "video" : "photo")
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(names.isEmpty ? item.kind.title : names.joined(separator: "、"))
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
    var quarterTurns = 0
    var fillsFrame = false
    var fallback: URL? = nil
    var contentID: String? = nil
    var missingLabel: String? = nil
    @State private var image: CGImage?
    @State private var loaded = false

    private struct Request: Equatable {
        let url: URL
        let fallback: URL?
        let contentID: String?
        let pixels: Int
    }

    var body: some View {
        Group {
            if let image {
                let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
                let turns = (quarterTurns % 4 + 4) % 4
                Image(uiImage: UIImage(cgImage: image, scale: 1, orientation: orientations[turns]))
                    .resizable()
                    .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                    if loaded, let missingLabel { Text(missingLabel).font(.caption2) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: Request(url: url, fallback: fallback, contentID: contentID, pixels: maxPixels)) {
            let result = await ThumbnailCache.shared.image(at: url, fallback: fallback, pixels: maxPixels, contentID: contentID)
            guard !Task.isCancelled else { return }
            image = result
            loaded = true
        }
    }
}

extension AssetImage {
    init(store: LibraryStore, item: LibraryMedia, maxPixels: Int, icon: String,
         fillsFrame: Bool = false, missingLabel: String? = nil) {
        let asset = item.enhanced == nil ? item.corrected ?? item.original : store.displayAsset(for: item)
        self.init(url: store.assetURL(asset), maxPixels: maxPixels,
                  icon: icon, quarterTurns: item.quarterTurns ?? 0, fillsFrame: fillsFrame,
                  fallback: asset.sha256 == item.original.sha256 ? nil : store.assetURL(item.original),
                  contentID: asset.sha256, missingLabel: missingLabel)
    }
}

struct NoteCoverImage: View {
    let library: AppLibrary
    let entry: LibraryEntry
    let height: CGFloat
    @State private var cover: LibraryMedia?

    private struct Request: Equatable {
        let revision: Int
        let cover: UUID?
        let media: [UUID]
    }

    var body: some View {
        Group {
            if let cover {
                AssetImage(store: library.store, item: cover, maxPixels: 960, icon: "photo",
                           fillsFrame: cover.kind != .cheki)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .background(Color.kinenCanvas)
            }
        }
        .task(id: Request(revision: library.snapshotVersion, cover: entry.coverMediaId, media: entry.mediaIds)) {
            let loaded = await library.noteCover(for: entry)
            if !Task.isCancelled { cover = loaded }
        }
    }
}

struct MediaDetail: View {
    let library: AppLibrary
    let item: LibraryMedia
    var contextEntry: LibraryEntry? = nil
    var browsingOrder: [LibraryMedia] = []
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var deletingMedia = false
    @State private var deletionError: String?
    @State private var writingMemory: LibraryEntry?
    @State private var editing = false
    @State private var inspectingPhoto = false
    @State private var cropping = false
    @State private var adjustingImage = false
    @State private var processingImage = false

    private var currentItem: LibraryMedia {
        library.snapshot.mediaByID[item.id] ?? item
    }
    @State private var player: AVPlayer?
    @State private var playbackFile: URL?
    @State private var playbackError: String?
    @State private var playbackAttempt = 0
    @State private var shareRequest: ShareRequest?
    private struct PlaybackRequest: Equatable {
        let asset: URL
        let attempt: Int
    }

    var body: some View {
        let item = currentItem
        let adjustmentBase = item.corrected ?? item.original
        let adjustmentSource = library.store.assetURL(adjustmentBase)
        List {
            if processingImage {
                ProgressView("正在更新照片…")
            }
            if item.kind == .video {
                if let message = playbackError {
                    ContentUnavailableView {
                        Label("无法播放视频", systemImage: "video.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") {
                            playbackError = nil
                            playbackAttempt += 1
                        }
                        .buttonStyle(.bordered)
                    }
                } else if let player, let playerItem = player.currentItem {
                    VideoPlayer(player: player)
                        .frame(height: 250)
                        .onReceive(playerItem.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                            guard status == .failed, self.player?.currentItem === playerItem else { return }
                            playbackError = "视频读取失败，可以重试。"
                            releasePlayback()
                        }
                } else {
                    ProgressView("正在读取视频…").frame(maxWidth: .infinity, minHeight: 180)
                }
            } else {
                Button {
                    inspectingPhoto = true
                } label: {
                    AssetImage(store: library.store, item: item, maxPixels: 1400, icon: "photo",
                               missingLabel: "附件缺失")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.medium))
                                .padding(8)
                                .background(Color.kinenPaper, in: Circle())
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全屏查看照片")
            }
            LabeledContent("拍摄日期", value: item.captureDate ?? "日期未知")
            let names = item.memberIds.compactMap { library.snapshot.membersByID[$0]?.name }
            if !names.isEmpty { LabeledContent("成员", value: names.joined(separator: "、")) }
            if let groupID = item.groupId, let group = library.snapshot.groupsByID[groupID] {
                LabeledContent("团体", value: group.name)
            }
            if !item.note.isEmpty { Text(item.note) }
            Section("相关笔记") {
                ForEach(library.snapshot.entries(linkingMedia: item.id)) { entry in
                    if entry.id == contextEntry?.id {
                        JournalRow(entry: entry)
                    } else {
                        NavigationLink {
                            JournalDetail(library: library, id: entry.id)
                        } label: {
                            JournalRow(entry: entry)
                        }
                    }
                }
                let isPortrait = item.kind == .cheki || item.kind == .portrait
                Button(isPortrait ? "写合影回忆" : "写一段回忆", systemImage: "square.and.pencil") {
                    let context = contextEntry.flatMap { library.snapshot.entriesByID[$0.id] }
                    let parent = context.flatMap { $0.kind.allowsChild(.memory) ? $0 : nil }
                    writingMemory = LibraryEntry(kind: .memory,
                        startDate: item.captureDate ?? parent?.startDate ?? LocalDay.today(),
                        parentId: parent?.id, mediaIds: [item.id], location: parent?.location)
                }
            }
            Section {
                Button("删除媒体", systemImage: "trash", role: .destructive) {
                    confirmingDeletion = true
                }
                .disabled(processingImage || shareRequest != nil)
            }
        }
        .kinenListStyle()
        .disabled(deletingMedia)
        .confirmationDialog("删除这项媒体？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteMedia(id: item.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法从资料库恢复。仍被笔记或草稿使用的媒体需先解除关联。")
        }
        .alert("无法删除媒体", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .navigationTitle(item.kind.title)
        .toolbar {
            Button("编辑") { editing = true }.disabled(processingImage)
            let displayedAsset = library.store.displayAsset(for: item)
            if library.store.assetURL(displayedAsset) != library.store.assetURL(item.original) {
                let label = displayedAsset.sha256 == item.enhanced?.sha256 ? "调整图" : "校正图"
                Menu("分享照片", systemImage: "square.and.arrow.up") {
                    Button("分享\(label)") { prepareShare(displayedAsset, name: label, quarterTurns: item.quarterTurns ?? 0) }
                    Button("分享原图") { prepareShare(item.original, name: "原图", quarterTurns: item.quarterTurns ?? 0) }
                }
                .disabled(shareRequest != nil || processingImage)
            } else {
                let label = item.kind == .video ? "视频" : "照片"
                Button("分享\(label)", systemImage: "square.and.arrow.up") {
                    prepareShare(item.original, name: label, quarterTurns: item.kind == .video ? 0 : item.quarterTurns ?? 0)
                }
                .disabled(shareRequest != nil || processingImage)
            }
            if item.kind == .cheki {
                Menu("调整照片", systemImage: "slider.horizontal.3") {
                    Button("图像调整", systemImage: "slider.horizontal.3") { adjustingImage = true }
                        .disabled(!FileManager.default.fileExists(atPath: adjustmentSource.path))
                    Button("四角校正", systemImage: "crop") { cropping = true }
                        .disabled(!FileManager.default.fileExists(atPath: library.store.assetURL(item.original).path))
                }
                .disabled(processingImage)
            }
        }
        .modifier(MediaSharing(request: $shareRequest))
        .sheet(item: $writingMemory) { JournalEditor(library: library, entry: $0) }
        .sheet(isPresented: $editing) {
            if item.kind == .cheki {
                ChekiDetailEditor(library: library, item: item)
            } else {
                MediaDetailsEditor(library: library, item: item)
            }
        }
        .fullScreenCover(isPresented: $inspectingPhoto) {
            let photos = browsingOrder.filter { $0.kind != .video }
            SavedPhotoViewer(library: library, photos: photos.contains(where: { $0.id == item.id }) ? photos : [item],
                             initialID: item.id)
        }
        .sheet(isPresented: $adjustingImage) {
            ChekiAdjustmentEditor(source: adjustmentSource, quarterTurns: item.quarterTurns ?? 0,
                                  values: item.adjustments ?? .init()) { values in
                let previous = item.adjustments ?? .init()
                guard previous != values,
                      !previous.isNeutral || !values.isNeutral || item.enhanced != nil else { return }
                processingImage = true
                Task {
                    defer { processingImage = false }
                    await saveChekiAdjustments(values, item: item, library: library)
                }
            }
        }
        .sheet(isPresented: $cropping) {
            ChekiCropView(source: library.store.assetURL(item.original), existing: item.correction) { corrected in
                processingImage = true
                Task {
                    defer {
                        corrected?.remove()
                        processingImage = false
                    }
                    _ = await library.perform {
                        var adjustments = item.adjustments ?? ChekiAdjustments()
                        if item.correction != corrected?.corners, adjustments.glareExclusions != nil {
                            adjustments.glareExclusions = []
                            adjustments.glareInclusions = nil
                        }
                        let source = corrected?.source ?? library.store.assetURL(item.original)
                        let enhanced = try await adjustments.export(at: source)
                        defer { if let enhanced { try? FileManager.default.removeItem(at: enhanced) } }
                        try await library.store.setChekiCorrection(id: item.id,
                            corrected: corrected.map { ($0.source, $0.corners) },
                            enhanced: enhanced.map { ($0, adjustments) })
                    }
                }
            }
        }
        .task(id: PlaybackRequest(asset: library.store.assetURL(item.original), attempt: playbackAttempt)) {
            guard item.kind == .video else { return }
            releasePlayback()
            playbackError = nil
            let source = library.store.assetURL(item.original)
            let fileExtension = assetExtension(for: item.original)
            let temporary = URL.temporaryDirectory.appending(path: UUID().uuidString)
            let target = fileExtension.isEmpty ? temporary : temporary.appendingPathExtension(fileExtension)
            var retained = false
            defer {
                if !retained { try? FileManager.default.removeItem(at: target) }
            }

            do {
                try await LibraryWork.run {
                    Result { try FileManager.default.linkItem(at: source, to: target) }
                }.get()
                try Task.checkCancellation()
                let asset = AVURLAsset(url: target)
                let playable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard playable else {
                    playbackError = "设备无法播放这种视频格式。"
                    return
                }
                playbackFile = target
                retained = true
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch {
                guard !Task.isCancelled else { return }
                let missing = !FileManager.default.fileExists(atPath: source.path)
                playbackError = missing ? "视频文件缺失。" : "视频读取失败，可以重试。"
            }
        }
        .onDisappear(perform: releasePlayback)
    }

    private func deleteMedia(id: UUID) {
        deletingMedia = true
        Task {
            defer { deletingMedia = false }
            do {
                try await library.store.deleteMedia(id: id)
                releasePlayback()
                await library.reload()
                dismiss()
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }

    private func prepareShare(_ asset: MediaAsset, name: String, quarterTurns: Int) {
        shareRequest = ShareRequest(asset: asset, store: library.store, name: name, quarterTurns: quarterTurns)
    }

    private func releasePlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let playbackFile { try? FileManager.default.removeItem(at: playbackFile) }
        playbackFile = nil
    }
}


@MainActor
private func saveChekiAdjustments(_ values: ChekiAdjustments, item: LibraryMedia, library: AppLibrary) async {
    let base = item.corrected ?? item.original
    let source = library.store.assetURL(base)
    _ = await library.perform {
        let enhanced = try await values.export(at: source)
        defer { if let enhanced { try? FileManager.default.removeItem(at: enhanced) } }
        try await library.store.setChekiAdjustments(id: item.id, baseSHA256: base.sha256,
                                                    enhanced: enhanced.map { ($0, values) })
    }
}

private struct ShareRequest: Equatable {
    let source: URL
    let name: String
    let fileExtension: String
    let quarterTurns: Int

    init(asset: MediaAsset, store: LibraryStore, name: String, quarterTurns: Int) {
        let turns = (quarterTurns % 4 + 4) % 4
        source = store.assetURL(asset)
        self.name = name
        fileExtension = turns == 0 ? assetExtension(for: asset) : "png"
        self.quarterTurns = turns
    }
}

private struct MediaSharing: ViewModifier {
    @Binding var request: ShareRequest?
    @State private var mediaShare: MediaShareFile?
    @State private var shareError = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $mediaShare) { file in
                MediaShareSheet(file: file)
            }
            .alert("无法分享媒体", isPresented: $shareError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("无法生成分享文件，请重试。")
            }
            .task(id: request) {
                guard let request, mediaShare == nil else { return }
                let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let base = directory.appending(path: request.name)
                let target = request.fileExtension.isEmpty ? base : base.appendingPathExtension(request.fileExtension)
                let result = await LibraryWork.run {
                    Result {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                        if request.quarterTurns == 0 {
                            try FileManager.default.linkItem(at: request.source, to: target)
                        } else {
                            try writeRotatedSharePhoto(from: request.source, to: target, quarterTurns: request.quarterTurns)
                        }
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                switch result {
                case .success:
                    mediaShare = MediaShareFile(url: target, directory: directory)
                case .failure:
                    try? FileManager.default.removeItem(at: directory)
                    shareError = true
                }
                self.request = nil
            }
    }
}

private func assetExtension(for asset: MediaAsset) -> String {
    let original = URL(fileURLWithPath: asset.originalFilename).pathExtension
    return original.isEmpty ? UTType(mimeType: asset.mimeType)?.preferredFilenameExtension ?? "" : original
}

private func writeRotatedSharePhoto(from source: URL, to target: URL, quarterTurns: Int) throws {
    guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    let rotated = image.oriented(orientations[quarterTurns])
    try CIContext().writePNGRepresentation(of: rotated, to: target, format: .RGBA8, colorSpace: colorSpace)
}

private final class MediaShareFile: Identifiable {
    let url: URL
    private let directory: URL

    init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct MediaShareSheet: UIViewControllerRepresentable {
    let file: MediaShareFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [file] _, _, _, _ in
            // Keep the temporary file available until the share activity finishes.
            withExtendedLifetime(file) {}
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SavedPhotoViewer: View {
    let library: AppLibrary
    let photos: [LibraryMedia]
    let initialID: UUID
    var showDetails: ((UUID) -> Void)? = nil
    @State private var selectedID: UUID?
    @State private var showsOriginal = false
    @State private var controlsVisible = true
    @State private var quickPreviews: [URL: CGImage] = [:]
    @State private var shareRequest: ShareRequest?

    var body: some View {
        if let index = photos.firstIndex(where: { $0.id == (selectedID ?? initialID) })
            ?? photos.firstIndex(where: { $0.id == initialID }) {
            let item = library.snapshot.mediaByID[photos[index].id] ?? photos[index]
            let original = library.store.assetURL(item.original)
            let displayAsset = library.store.displayAsset(for: item)
            let display = library.store.assetURL(displayAsset)
            let processedLabel = displayAsset.sha256 == item.enhanced?.sha256 ? "调整图" : "校正图"
            let neighbors = [index - 1, index + 1].filter { photos.indices.contains($0) }.map { index in
                let neighbor = library.snapshot.mediaByID[photos[index].id] ?? photos[index]
                return library.store.displayURL(for: neighbor)
            }
            PhotoInspectionView(original: original, corrected: display == original ? nil : display,
                                quarterTurns: item.quarterTurns ?? 0, showsOriginal: $showsOriginal,
                                position: photos.count > 1 ? "\(index + 1) / \(photos.count)" : nil,
                                previous: index > 0 ? { select(index - 1) } : nil,
                                next: index + 1 < photos.count ? { select(index + 1) } : nil,
                                showDetails: showDetails.map { action in { action(item.id) } },
                                controlsVisibility: $controlsVisible, quickPreview: quickPreviews[display],
                                sharePhoto: {
                                    guard shareRequest == nil else { return }
                                    let sharingProcessed = !showsOriginal && display != original
                                    shareRequest = ShareRequest(asset: sharingProcessed ? displayAsset : item.original,
                                                                store: library.store,
                                                                name: sharingProcessed ? processedLabel : "原图",
                                                                quarterTurns: item.quarterTurns ?? 0)
                                }, processedLabel: processedLabel)
                .id(item.id)
                .task(id: neighbors) {
                    // Keep the current preview alive while its full-size image loads.
                    quickPreviews = quickPreviews.filter { $0.key == display || neighbors.contains($0.key) }
                    do { try await Task.sleep(for: .milliseconds(180)) }
                    catch { return }
                    for url in neighbors where quickPreviews[url] == nil {
                        let image = await ThumbnailCache.shared.image(at: url, fallback: nil, pixels: 640, contentID: nil)
                        guard !Task.isCancelled else { return }
                        quickPreviews[url] = image
                    }
                }
                .modifier(MediaSharing(request: $shareRequest))
        }
    }

    private func select(_ index: Int) {
        showsOriginal = false
        selectedID = photos[index].id
    }
}

private struct MediaDetailsEditor: View {
    let library: AppLibrary
    let item: LibraryMedia

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var knowsDate: Bool
    @State private var members: Set<UUID>
    @State private var showsMembers = false
    @State private var memberSearch = ""
    @State private var addingMember = false
    @State private var note: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(library: AppLibrary, item: LibraryMedia) {
        self.library = library
        self.item = item
        let captured = item.captureDate.flatMap(LocalDay.date(from:))
        _date = State(initialValue: captured ?? .now)
        _knowsDate = State(initialValue: captured != nil)
        _members = State(initialValue: Set(item.memberIds))
        _note = State(initialValue: item.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("拍摄日期") {
                    Toggle("知道拍摄日期", isOn: $knowsDate)
                    if knowsDate { DatePicker("日期", selection: $date, displayedComponents: .date) }
                }
                Section("成员") {
                    DisclosureGroup(members.isEmpty ? "选择成员" : "已选 \(members.count) 位", isExpanded: $showsMembers) {
                        let query = LibraryQuery(memberSearch)
                        if !library.snapshot.members.isEmpty {
                            TextField("搜索姓名或别名", text: $memberSearch)
                        }
                        let visible = library.snapshot.members.filter { member in
                            (!member.archived || item.memberIds.contains(member.id)) &&
                                query.matches([member.name] + member.aliases)
                        }
                        ForEach(visible) { member in
                            Toggle(isOn: Binding(
                                get: { members.contains(member.id) },
                                set: { selected in
                                    if selected { members.insert(member.id) }
                                    else { members.remove(member.id) }
                                }
                            )) { MemberProfileRow(member: member) }
                        }
                        if visible.isEmpty {
                            Text(query.isEmpty ? "还没有可选成员。" : "没有找到符合条件的成员。")
                                .font(.footnote).foregroundStyle(Color.kinenMuted)
                        }
                        Button("添加成员", systemImage: "person.badge.plus") { addingMember = true }
                    }
                }
                Section("回忆") {
                    TextField("写下当时的回忆", text: $note, axis: .vertical).lineLimit(3...8)
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.circle").font(.footnote) }
                }
            }
            .kinenListStyle()
            .navigationTitle("编辑" + item.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $addingMember) {
                MemberEditor(library: library) { member in members.insert(member.id) }
            }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        let day = knowsDate ? LocalDay.string(from: date) : nil
        let selected = members
        let text = note
        Task {
            defer { saving = false }
            do {
                try await library.store.updateMediaDetails(id: item.id, captureDate: day, memberIds: selected, note: text)
                await library.reload()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ChekiDetailEditor: View {
    let library: AppLibrary
    let item: LibraryMedia
    @Environment(\.dismiss) private var dismiss
    @State private var subject: ChekiSubject?
    @State private var date: Date
    @State private var note: String
    @State private var turns: Int
    @State private var saving = false
    @State private var errorMessage: String?

    init(library: AppLibrary, item: LibraryMedia) {
        self.library = library
        self.item = item
        _subject = State(initialValue: item.chekiSubject)
        _date = State(initialValue: item.captureDate.flatMap(LocalDay.date(from:)) ?? .now)
        _note = State(initialValue: item.note)
        _turns = State(initialValue: item.quarterTurns ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AssetImage(url: library.store.displayURL(for: item), maxPixels: 1200,
                               icon: "photo", quarterTurns: turns)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                    Button("顺时针旋转", systemImage: "rotate.right") { turns = (turns + 1) % 4 }
                }
                Section {
                    ChekiSubjectPicker(library: library, subject: $subject)
                    DatePicker("拍摄日期", selection: $date, displayedComponents: .date)
                }
                Section("回忆") {
                    TextField("写下当时的回忆", text: $note, axis: .vertical).lineLimit(3...8)
                }
                if let errorMessage { Text(errorMessage).font(.footnote) }
            }
            .disabled(saving)
            .kinenListStyle()
            .navigationTitle("编辑拍立得")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(subject == nil || saving)
                }
            }
        }
    }

    private func save() {
        guard let subject else { return }
        saving = true
        errorMessage = nil
        let date = LocalDay.string(from: date)
        let note = note
        let turns = turns
        Task {
            defer { saving = false }
            do {
                try await library.store.updateCheki(id: item.id, subject: subject, captureDate: date,
                                                    note: note, quarterTurns: turns)
                await library.reload()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MemberProfileRow: View {
    let member: Member

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatar(name: member.name, data: member.avatarJPEG, size: 34,
                         identity: "\(member.id)-\(member.updatedAt.timeIntervalSinceReferenceDate)")
            Text(member.name)
            HStack(spacing: 4) {
                swatch(member.supportColors?.first)
                swatch(member.supportColors?.second)
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func swatch(_ hex: String?) -> some View {
        if let hex, let color = Color(memberHex: hex) {
            Circle().fill(color).overlay { Circle().strokeBorder(.primary.opacity(0.22)) }
                .frame(width: 10, height: 10)
        }
    }
}

private struct MemberAvatar: View {
    let name: String
    let data: Data?
    let size: CGFloat
    var identity: String? = nil
    @State private var preview: CGImage?

    var body: some View {
        Group {
            if let image = preview {
                Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFill()
            } else if let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(first).uppercased())
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "person")
                    .font(.system(size: size * 0.33, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .background(.primary.opacity(0.07))
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.primary.opacity(0.12)) }
        .accessibilityHidden(true)
        .task(id: data) {
            guard let data else { preview = nil; return }
            let image = await ThumbnailCache.shared.avatar(data, pixels: Int(size * 3), identity: identity)
            if !Task.isCancelled { preview = image }
        }
    }
}

struct MemberEditor: View {
    let library: AppLibrary
    let member: Member?
    let didSave: (Member) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: Data?
    @State private var aliasText: String
    @State private var archived: Bool
    @State private var showsProfile = false
    @FocusState private var focusesName: Bool
    @State private var first: String?
    @State private var second: String?
    @State private var photo: PhotosPickerItem?
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?

    init(library: AppLibrary, member: Member? = nil, didSave: @escaping (Member) -> Void = { _ in }) {
        self.library = library
        self.member = member
        self.didSave = didSave
        _name = State(initialValue: member?.name ?? "")
        _avatar = State(initialValue: member?.avatarJPEG)
        _aliasText = State(initialValue: member?.aliases.joined(separator: "\n") ?? "")
        _archived = State(initialValue: member?.archived ?? false)
        _first = State(initialValue: member?.supportColors?.first)
        _second = State(initialValue: member?.supportColors?.second)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        if let member {
                            MemberAvatar(name: name, data: avatar, size: 40,
                                         identity: avatar == member.avatarJPEG ? "\(member.id)-\(member.updatedAt.timeIntervalSinceReferenceDate)" : nil)
                        }
                        TextField("成员姓名", text: $name)
                            .focused($focusesName)
                            .submitLabel(.done)
                            .onSubmit {
                                if !showsProfile && canSave { save() }
                            }
                    }
                }
                Section {
                    DisclosureGroup("头像、应援色与别名", isExpanded: $showsProfile) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            HStack {
                                MemberAvatar(name: name, data: avatar, size: 48)
                                Text(avatar == nil ? "选择头像" : "更换头像")
                            }
                        }
                        .disabled(loading)
                        if loading {
                            ProgressView("正在读取头像…")
                        } else if avatar != nil {
                            Button("移除头像") {
                                avatar = nil
                                photo = nil
                            }
                        }
                        colorRow("应援色一", value: $first)
                        colorRow("应援色二", value: $second)
                        TextField("别名（可选，每行一个）", text: $aliasText, axis: .vertical)
                            .lineLimit(1...5)
                    }
                }
                if member != nil {
                    Section {
                        Toggle("归档成员", isOn: $archived)
                    } footer: {
                        Text("归档成员会从新增归属的列表中隐藏。历史记录仍可查看。")
                    }
                }
            }
            .kinenListStyle()
            .navigationTitle(member == nil ? "添加成员" : "编辑成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                if member == nil { focusesName = true }
            }
            .task(id: photo) {
                guard let photo else { return }
                loading = true
                defer { loading = false }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self),
                          let image = memberThumbnail(from: data, pixels: 256),
                          let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
                    else { throw LibraryError.invalidAsset }
                    try Task.checkCancellation()
                    avatar = jpeg
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func colorRow(_ title: String, value: Binding<String?>) -> some View {
        HStack(spacing: 12) {
            ColorPicker(selection: Binding(
                get: { value.wrappedValue.flatMap { Color(memberHex: $0) } ?? .gray },
                set: { if let hex = $0.memberHex { value.wrappedValue = hex } }
            ), supportsOpacity: false) {
                LabeledContent(title, value: value.wrappedValue.map { "#" + $0 } ?? "未设置")
            }
            if value.wrappedValue != nil {
                Button {
                    value.wrappedValue = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除\(title)")
            }
        }
    }

    private var canSave: Bool {
        !saving && !loading && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        saving = true
        let colors = MemberSupportColors(first: first, second: second)
        let aliases = aliasText.split(whereSeparator: \.isNewline).map(String.init)
        Task {
            defer { saving = false }
            do {
                let updated = try await library.store.saveMember(id: member?.id, name: name,
                                                                  avatarJPEG: avatar, colors: colors,
                                                                  aliases: aliases, archived: archived)
                await library.reload()
                didSave(updated)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private func memberThumbnail(from data: Data, pixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels
    ] as CFDictionary)
}

private extension Color {
    init?(memberHex: String) {
        guard memberHex.count == 6, let rgb = UInt32(memberHex, radix: 16) else { return nil }
        self.init(.sRGB, red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }

    var memberHex: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

struct MediaGrid: View {
    let library: AppLibrary
    let items: [LibraryMedia]
    var openPhoto: ((LibraryMedia) -> Void)? = nil
    var openPhotoDetails: ((LibraryMedia) -> Void)? = nil
    var sharePhoto: ((LibraryMedia) -> Void)? = nil
    @State private var chekiAction: ChekiAction?
    @State private var quickShare: ShareRequest?
    @State private var updating = false

    private enum ChekiAction: Identifiable {
        case adjust(LibraryMedia), edit(LibraryMedia)

        var id: UUID {
            switch self {
            case .adjust(let photo), .edit(let photo): photo.id
            }
        }
    }

    @ScaledMetric(relativeTo: .body) private var tileWidth = 95.0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 8)], spacing: 8) {
            ForEach(items) { item in
                Group {
                    if let openPhoto, item.kind != .video {
                        Button { openPhoto(item) } label: { tile(item) }
                            .contextMenu {
                                if let openPhotoDetails {
                                    Button("查看详情", systemImage: "info.circle") { openPhotoDetails(item) }
                                }
                                if let sharePhoto {
                                    Button("分享照片", systemImage: "square.and.arrow.up") { sharePhoto(item) }
                                }
                            }
                    } else {
                        NavigationLink {
                            MediaDetail(library: library, item: item, browsingOrder: items)
                        } label: {
                            tile(item)
                        }
                        .contextMenu {
                            if item.kind == .cheki {
                                Button("图像调整", systemImage: "slider.horizontal.3") { chekiAction = .adjust(item) }
                                    .disabled(updating || !FileManager.default.fileExists(atPath: library.store.assetURL(item.corrected ?? item.original).path))
                                Button("修改归属与日期", systemImage: "person.crop.circle") { chekiAction = .edit(item) }
                                    .disabled(updating)
                                Button("分享照片", systemImage: "square.and.arrow.up") {
                                    let asset = library.store.displayAsset(for: item)
                                    quickShare = ShareRequest(asset: asset, store: library.store, name: "拍立得",
                                                              quarterTurns: item.quarterTurns ?? 0)
                                }
                                .disabled(updating || quickShare != nil)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(MediaSharing(request: $quickShare))
        .sheet(item: $chekiAction) { action in
            switch action {
            case .edit(let item):
                ChekiDetailEditor(library: library, item: item)
            case .adjust(let item):
                ChekiAdjustmentEditor(source: library.store.assetURL(item.corrected ?? item.original),
                                      quarterTurns: item.quarterTurns ?? 0, values: item.adjustments ?? .init()) { values in
                    let previous = item.adjustments ?? .init()
                    guard previous != values, !previous.isNeutral || !values.isNeutral else { return }
                    updating = true
                    Task {
                        defer { updating = false }
                        await saveChekiAdjustments(values, item: item, library: library)
                    }
                }
            }
        }
    }

    private func tile(_ item: LibraryMedia) -> some View {
        Color.kinenPaper
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.kind == .video {
                    VideoTile(store: library.store, item: item)
                } else {
                    AssetImage(store: library.store, item: item, maxPixels: 420, icon: "photo",
                               fillsFrame: item.kind != .cheki)
                        .padding(item.kind == .cheki ? 8 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kinenLine) }
            .accessibilityLabel("\(item.kind.title)，\(item.captureDate ?? "日期未知")")
    }
}

struct VideoTile: View {
    let url: URL
    let filenameExtension: String

    init(url: URL, filenameExtension: String = "") {
        self.url = url
        self.filenameExtension = filenameExtension
    }

    init(store: LibraryStore, item: LibraryMedia) {
        self.init(url: store.assetURL(item.original), filenameExtension: assetExtension(for: item.original))
    }
    @State private var image: CGImage?
    @State private var seconds: Int?

    var body: some View {
        Color.kinenCanvas
            .overlay {
                if let image {
                    Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.semibold))
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .overlay(alignment: .bottomTrailing) {
                if let seconds {
                    Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(5)
                }
            }
            .task(id: url) {
                let thumbnail = await ThumbnailCache.shared.video(at: url, filenameExtension: filenameExtension)
                guard !Task.isCancelled else { return }
                image = thumbnail.image
                seconds = thumbnail.seconds
            }
    }
}
