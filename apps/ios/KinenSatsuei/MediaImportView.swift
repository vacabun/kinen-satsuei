import CoreTransferable
import KinenCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import UIKit

struct MediaImportView: View {
    let library: AppLibrary
    var startScanning = false
    var entry: LibraryEntry?
    var onShowCollection: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var photo: PhotosPickerItem?
    @State private var photos: [PhotosPickerItem] = []
    @State private var pending: [PhotosPickerItem] = []
    @State private var batchTotal = 0
    @State private var batchProgress = 0
    @State private var failedPhoto: PhotosPickerItem?
    @State private var copyDetails = false
    @State private var generalCamera = false
    @State private var requestedCamera = false
    @State private var savedItem: LibraryMedia?
    @State private var showOriginal = false
    @State private var inspectingPhoto = false
    @State private var showsAdjustments = false
    @State private var showsMemory = false
    @State private var cameraMode = true
    @State private var destinationID: UUID?
    @State private var cameraDenied = false
    @State private var source: ImportFile?
    @State private var capturedWithCamera = false
    @State private var scanning = false
    @State private var cropping = false
    @State private var correction: ChekiCorrectionFile?
    @State private var imageAdjustments = ChekiAdjustments()
    @State private var adjustingImage = false
    @State private var kind = MediaKind.photo
    @State private var quarterTurns = 0
    @State private var note = ""
    @State private var knowsDate = true
    @State private var date = Date.now
    @State private var memberIds: Set<UUID> = []
    @State private var subject: ChekiSubject?
    @State private var subjectPickerRequest = 0
    @State private var addingMember = false
    @State private var loading = false
    @State private var saving = false
    @State private var errorMessage: String?

    @State private var scanBatch = false
    @State private var appendingScans = false
    @State private var scans: [ScanDraft] = []
    @State private var activeScan: UUID?
    @State private var scanFailures: [UUID: String] = [:]
    @State private var editingBatch = false
    @State private var batchImageOnly = false
    @State private var discardAction: ScanDiscard?
    @State private var savedScanCount = 0
    @State private var processedScans = 0
    @State private var scanAttemptCount = 0

    private enum ScanDiscard {
        case current, batch

        var title: String {
            self == .current ? "移除当前这张拍立得？" : "放弃这批尚未归档的拍立得？"
        }
    }

    fileprivate struct ScanDraft: Identifiable {
        var id = UUID()
        var file: ImportFile
        var correction: ChekiCorrectionFile?
        var adjustments = ChekiAdjustments()
        var subject: ChekiSubject?
        var date: Date
        var note = ""
        var turns = 0
        var destination: UUID?

        func removeFiles() {
            file.remove()
            correction?.remove()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if scanBatch && !scans.isEmpty { scanQueue }
                        if let source {
                            if batchTotal > 1 {
                                LabeledContent("导入进度", value: "\(batchProgress) / \(batchTotal)")
                                    .font(.subheadline.monospacedDigit())
                            }
                            preview(source)
                            if kind == .cheki {
                                Button("图像调整", systemImage: "slider.horizontal.3") { adjustingImage = true }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                subjectCard.id("subject")
                            } else {
                                recordingCard
                                membersCard
                            }
                            optionalDetails(video: source.isVideo)
                            if !pending.isEmpty {
                                Toggle("将类型、日期和归属用于后续 \(pending.count) 项", isOn: $copyDetails)
                                    .padding(12)
                                    .kinenCard(radius: 16)
                            }
                        } else if let savedItem {
                            savedCard(savedItem)
                        } else {
                            sourceCard
                        }
                        if loading { ProgressView("正在读取媒体…").frame(maxWidth: .infinity) }
                        if source == nil && !loading, let failedPhoto {
                            Button("重试这一项") { loadBatchItem(failedPhoto) }.frame(minHeight: 44)
                            if !pending.isEmpty {
                                Button("跳过，继续下一项", action: advanceBatch).frame(minHeight: 44)
                            }
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                        }
                    }
                    .disabled(saving || loading)
                    .frame(maxWidth: 540)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.kinenCanvas)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if source != nil {
                        Button {
                            if scanBatch {
                                if !saveScanBatch() { reader.scrollTo("subject", anchor: .top) }
                            }
                            else if kind == .cheki && subject == nil {
                                subjectPickerRequest &+= 1
                            } else { save() }
                        } label: {
                            Group {
                                if saving && scanBatch {
                                    HStack {
                                        ProgressView().tint(.kinenOnInk)
                                        Text("已处理 \(processedScans) / \(scanAttemptCount)")
                                            .monospacedDigit()
                                    }
                                    .accessibilityElement(children: .combine)
                                } else if saving { ProgressView().tint(.kinenOnInk).accessibilityLabel("正在保存") }
                                else if scanBatch { Text("归档 \(scans.count) 张拍立得") }
                                else if kind == .cheki { Text(subject == nil ? "选择归属" : "保存拍立得") }
                                else { Text("保存媒体") }
                            }
                            .kinenPrimaryButton()
                        }
                        .buttonStyle(.plain)
                        .disabled(loading || saving)
                        .frame(maxWidth: 540)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.kinenCanvas)
                    }
                }
            }
            .navigationTitle(source == nil ? "添加媒体" : kind == .cheki ? "拍立得预览" : "媒体预览")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedItem == nil ? "取消" : "完成") {
                        if scanBatch && !scans.isEmpty { discardAction = .batch }
                        else { discardAndDismiss() }
                    }
                    .disabled(saving || loading)
                }
                if capturedWithCamera {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("重拍这张") {
                            appendingScans = false
                            openCamera(scan: true)
                        }.disabled(saving || loading)
                    }
                } else if source != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                            Text("更换")
                        }
                        .disabled(loading || saving)
                    }
                }
            }
            .sheet(isPresented: $addingMember) {
                MemberEditor(library: library) { member in
                    if kind == .cheki { subject = .member(member.id) }
                    else { memberIds.insert(member.id) }
                }
            }
            .sheet(isPresented: $editingBatch) {
                ScanBatchEditor(library: library, scans: scans, initialSubject: subject, initialDate: date,
                                currentAdjustments: imageAdjustments, imageOnly: batchImageOnly) { ids, sharedSubject, sharedDate, sharedAdjustments in
                    for index in scans.indices where ids.contains(scans[index].id) {
                        if let sharedSubject { scans[index].subject = sharedSubject }
                        if let sharedDate { scans[index].date = sharedDate }
                        if let sharedAdjustments {
                            scans[index].adjustments.exposure = sharedAdjustments.exposure
                            scans[index].adjustments.contrast = sharedAdjustments.contrast
                            scans[index].adjustments.saturation = sharedAdjustments.saturation
                            scans[index].adjustments.glare = sharedAdjustments.glare
                            if sharedAdjustments.glare > 0, scans[index].adjustments.glareExclusions == nil {
                                scans[index].adjustments.glareExclusions = []
                            }
                        }
                    }
                    if let current = scans.first(where: { $0.id == activeScan }) { loadScan(current) }
                }
            }
            .confirmationDialog(discardAction?.title ?? "移除未归档的照片？", isPresented: Binding(
                get: { discardAction != nil },
                set: { if !$0 { discardAction = nil } }
            ), titleVisibility: .visible, presenting: discardAction) { action in
                if action == .current {
                    Button("移除照片", role: .destructive) { removeCurrentScan() }
                } else {
                    Button("放弃待归档照片", role: .destructive) { discardAndDismiss() }
                }
                Button("取消", role: .cancel) {}
            } message: { action in
                if action == .current {
                    Text("这张照片尚未归档，移除后可重新扫描。")
                } else {
                    Text("尚未归档的 \(scans.count) 张将被移除，已归档的照片仍在资料库中。")
                }
            }
            .presentationDetents(source == nil && savedItem == nil && !scanBatch ? [.height(400), .large] : [.large])
            .interactiveDismissDisabled(source != nil || saving || loading || !pending.isEmpty || !scans.isEmpty)
            .task {
                guard !requestedCamera else { return }
                requestedCamera = true
                destinationID = entry?.id
                if startScanning { openCamera(scan: true) }
            }
            .onChange(of: photos) { _, selection in
                guard !selection.isEmpty else { return }
                scanBatch = false
                photos = []
                pending = selection
                batchTotal = selection.count
                batchProgress = 0
                advanceBatch()
            }
            .alert("无法打开相机", isPresented: $cameraDenied) {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("请允许相机访问，或从相册导入。") }
            .fullScreenCover(isPresented: $generalCamera) {
                LibraryCamera { result in
                    generalCamera = false
                    do {
                        if let file = try result.get() {
                            replaceSource(file)
                            capturedWithCamera = false
                            kind = file.isVideo ? .video : .photo
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
                .ignoresSafeArea()
            }
            .task(id: photo) {
                guard let photo else { return }
                loading = true
                errorMessage = nil
                defer { loading = false }
                do {
                    guard let file = try await photo.loadTransferable(type: ImportFile.self) else {
                        throw LibraryError.invalidAsset
                    }
                    if Task.isCancelled {
                        file.remove()
                        return
                    }
                    replaceSource(file)
                    capturedWithCamera = false
                    kind = file.isVideo ? .video : .photo
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
            .sheet(isPresented: $cropping) {
                if let source {
                    ChekiCropView(source: source.url, existing: correction?.corners) { updated in
                        if correction?.corners != updated?.corners, imageAdjustments.glareExclusions != nil {
                            imageAdjustments.glareExclusions = []
                            imageAdjustments.glareInclusions = nil
                        }
                        correction?.remove()
                        correction = updated
                        showOriginal = false
                        if scanBatch { stashActiveScan() }
                    }
                }
            }
            .sheet(isPresented: $adjustingImage) {
                if let source {
                    ChekiAdjustmentEditor(source: correction?.source ?? source.url, quarterTurns: quarterTurns,
                                          values: imageAdjustments) { values in
                        imageAdjustments = values
                        showOriginal = false
                        if scanBatch { stashActiveScan() }
                    }
                }
            }
            .fullScreenCover(isPresented: $inspectingPhoto) {
                if let source, !source.isVideo {
                    let adjustments = kind == .cheki && !imageAdjustments.isNeutral ? imageAdjustments : nil
                    PhotoInspectionView(original: source.url,
                                        corrected: kind == .cheki ? correction?.source ?? (adjustments == nil ? nil : source.url) : nil,
                                        quarterTurns: quarterTurns, showsOriginal: $showOriginal,
                                        adjustments: adjustments)
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                ChekiCameraView(
                    autoCapture: $cameraMode,
                    onCancel: { scanning = false },
                    continuousCount: scanBatch && appendingScans ? scans.count : nil,
                    preparingCapture: loading,
                    onReview: { scanning = false },
                    onStartContinuous: source == nil && !scanBatch ? {
                        scanBatch = true
                        appendingScans = true
                    } : nil
                ) { image in
                    guard scanning, !loading else { return }
                    let append = scanBatch && appendingScans
                    if !append { scanning = false }
                    acceptCapture(image, appendToBatch: append)
                }
            }
        }
    }

    private func acceptCapture(_ image: ChekiCapturedPhoto, appendToBatch: Bool) {
        loading = true
        errorMessage = nil
        Task {
            defer { loading = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
                    do {
                        try image.original.write(to: url, options: .atomic)
                        let corrected = try image.correction.map {
                            try ChekiCorrectionFile($0.data, corners: $0.corners)
                        }
                        let file = ImportFile(url: url, filename: "扫描拍立得.jpg", mimeType: "image/jpeg", isVideo: false)
                        return (file, corrected)
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                }.value
                if appendToBatch {
                    guard scans.count < 30 else {
                        prepared.0.remove()
                        prepared.1?.remove()
                        return
                    }
                    stashActiveScan()
                    let draft = ScanDraft(file: prepared.0, correction: prepared.1, subject: nil,
                                          date: .now, destination: entry?.id)
                    scans.append(draft)
                    loadScan(draft)
                    if scans.count == 30 { scanning = false }
                } else {
                    replaceSource(prepared.0)
                    correction = prepared.1
                    capturedWithCamera = true
                    photo = nil
                    kind = .cheki
                    if scanBatch {
                        stashActiveScan()
                        if let activeScan { scanFailures[activeScan] = nil }
                    }
                }
            } catch {
                if appendToBatch { scanning = false }
                errorMessage = source == nil ? error.localizedDescription : "新照片保存失败，上一张已保留。"
            }
        }
    }

    private func startScanBatch() {
        scanBatch = true
        appendingScans = true
        openCamera(scan: true)
    }

    private var scanQueue: some View {
        card("待归档 · \(scans.count) 张", icon: "square.stack") {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(scans.enumerated()), id: \.element.id) { index, draft in
                            Button {
                                stashActiveScan()
                                if let stored = scans.first(where: { $0.id == draft.id }) { loadScan(stored) }
                            } label: {
                                VStack(spacing: 5) {
                                    AssetImage(url: draft.correction?.source ?? draft.file.url,
                                               maxPixels: 210, icon: "photo", quarterTurns: draft.turns)
                                        .frame(width: 68, height: 78)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay {
                                            if activeScan == draft.id {
                                                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kinenInk, lineWidth: 2)
                                            }
                                        }
                                    Text("第 \(index + 1) 张").font(.caption)
                                    if scanFailures[draft.id] != nil {
                                        Label("待处理", systemImage: "exclamationmark.circle").font(.caption2)
                                    } else if (draft.id == activeScan ? subject : draft.subject) == nil {
                                        Text("待填归属").font(.caption2).foregroundStyle(Color.kinenMuted)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(activeScan == draft.id ? .isSelected : [])
                            .id(draft.id)
                        }
                    }
                }
                .task(id: activeScan) {
                    if let activeScan { reader.scrollTo(activeScan) }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { scanActions }
                VStack(alignment: .leading, spacing: 8) { scanActions }
            }
            if let activeScan, let issue = scanFailures[activeScan] {
                Text(issue).font(.footnote).foregroundStyle(Color.kinenMuted)
            }
        }
        .disabled(loading || saving)
    }

    @ViewBuilder private var scanActions: some View {
        Button("继续拍摄", systemImage: "camera") {
            stashActiveScan()
            startScanBatch()
        }
        .disabled(scans.count >= 30)
        Button("批量填写", systemImage: "checklist") {
            batchImageOnly = false
            stashActiveScan()
            editingBatch = true
        }
        Menu("当前照片", systemImage: "ellipsis.circle") {
            Button("重拍这张", systemImage: "camera") {
                appendingScans = false
                openCamera(scan: true)
            }
            Button("批量套用图像调整", systemImage: "slider.horizontal.3") {
                batchImageOnly = true
                stashActiveScan()
                editingBatch = true
            }
            .disabled(scans.count < 2)
            Button("移除当前照片", systemImage: "trash", role: .destructive) { discardAction = .current }
        }
    }

    private func stashActiveScan() {
        guard let file = source, let index = scans.firstIndex(where: { $0.id == activeScan }) else { return }
        scans[index].file = file
        scans[index].correction = correction
        scans[index].adjustments = imageAdjustments
        scans[index].subject = subject
        scans[index].date = date
        scans[index].note = note
        scans[index].turns = quarterTurns
        scans[index].destination = destinationID
    }

    private func loadScan(_ draft: ScanDraft) {
        activeScan = draft.id
        source = draft.file
        correction = draft.correction
        imageAdjustments = draft.adjustments
        subject = draft.subject
        date = draft.date
        note = draft.note
        showsMemory = false
        showsAdjustments = false
        quarterTurns = draft.turns
        destinationID = draft.destination
        capturedWithCamera = true
        kind = .cheki
        savedItem = nil
        showOriginal = false
        errorMessage = nil
    }

    private func removeCurrentScan() {
        stashActiveScan()
        guard let index = scans.firstIndex(where: { $0.id == activeScan }) else { return }
        let removed = scans.remove(at: index)
        removed.removeFiles()
        scanFailures[removed.id] = nil
        if let next = scans.isEmpty ? nil : scans[min(index, scans.count - 1)] { loadScan(next) }
        else { clearActiveScan() }
    }

    private func clearActiveScan() {
        activeScan = nil
        source = nil
        correction = nil
        imageAdjustments = .init()
        capturedWithCamera = false
    }

    private func discardAndDismiss() {
        stashActiveScan()
        if activeScan == nil {
            source?.remove()
            correction?.remove()
        }
        scans.forEach { $0.removeFiles() }
        dismiss()
    }

    @discardableResult
    private func saveScanBatch() -> Bool {
        guard !saving, !scans.isEmpty else { return false }
        stashActiveScan()
        if let missing = scans.first(where: { $0.subject == nil }) {
            loadScan(missing)
            errorMessage = "还有照片没有归属。可以逐张填写，也可以使用「批量填写」。"
            return false
        }

        let batch = scans
        let store = library.store
        processedScans = 0
        scanAttemptCount = batch.count
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            var remaining: [ScanDraft] = []
            var failures: [UUID: String] = [:]
            var latest: LibraryMedia?
            for scan in batch {
                do {
                    let enhanced = try await scan.adjustments.export(at: scan.correction?.source ?? scan.file.url)
                    defer { if let enhanced { try? FileManager.default.removeItem(at: enhanced) } }
                    latest = try await store.importMedia(
                        from: scan.file.url, filename: scan.file.filename,
                        mimeType: scan.file.mimeType, kind: .cheki,
                        captureDate: LocalDay.string(from: scan.date), memberIds: [],
                        chekiSubject: scan.subject, note: scan.note, quarterTurns: scan.turns,
                        corrected: scan.correction.map { ($0.source, $0.corners) }, enhanced: enhanced.map { ($0, scan.adjustments) }, attachTo: scan.destination
                    )
                    library.rememberChekiSubject(scan.subject)
                    scan.removeFiles()
                } catch {
                    remaining.append(scan)
                    failures[scan.id] = error.localizedDescription
                }
                processedScans += 1
            }
            let count = batch.count - remaining.count
            scans = remaining
            scanFailures = failures
            savedScanCount += count
            if let first = remaining.first {
                loadScan(first)
                errorMessage = "已归档 \(count) 张，剩余 \(remaining.count) 张可检查后重试。"
            } else {
                clearActiveScan()
                savedItem = latest
            }
            if count > 0 { await library.reload() }
        }
        return true
    }

    private func openCamera(scan: Bool) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "此设备无法打开相机，可以从相册导入。"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if scan { scanning = true } else { generalCamera = true }
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    if scan { scanning = true } else { generalCamera = true }
                } else { cameraDenied = true }
            }
        default: cameraDenied = true
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry != nil { destinationPicker }
            Button {
                scanBatch = false
                openCamera(scan: true)
            } label: {
                Label("扫描拍立得", systemImage: "camera.viewfinder").kinenPrimaryButton()
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                PhotosPicker(selection: $photos, maxSelectionCount: 30, selectionBehavior: .ordered,
                             matching: .any(of: [.images, .videos])) {
                    sourceLabel("从相册导入", icon: "photo.on.rectangle")
                }
                Divider().padding(.leading, 16)
                Button {
                    scanBatch = false
                    openCamera(scan: false)
                } label: {
                    sourceLabel("拍摄照片或视频", icon: "camera")
                }
            }
            .buttonStyle(.plain)
            .kinenCard()
        }
        .disabled(loading || saving)
    }

    private func sourceLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 25)
            Text(title).font(.headline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.kinenMuted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }

    private var destinationPicker: some View {
        Picker("关联笔记", selection: $destinationID) {
            Text("不关联").tag(nil as UUID?)
            ForEach(library.snapshot.entries) { entry in
                Text(entry.title).tag(Optional(entry.id))
            }
        }
        .padding(12)
        .kinenCard(radius: 16)
    }

    private func savedCard(_ item: LibraryMedia) -> some View {
        VStack(spacing: 14) {
            Label("已保存", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold))
            if savedScanCount > 0 {
                Text("已归档 \(savedScanCount) 张拍立得").font(.subheadline).foregroundStyle(Color.kinenMuted)
            } else if batchTotal > 1 {
                Text("已处理 \(batchProgress) 项").font(.subheadline).foregroundStyle(Color.kinenMuted)
            }
            NavigationLink {
                MediaDetail(library: library, item: item)
            } label: {
                Text(item.kind == .cheki ? "查看拍立得" : "查看媒体").kinenPrimaryButton()
            }
            .buttonStyle(.plain)
            if item.kind == .cheki, let onShowCollection {
                Button("查看收藏", systemImage: "heart") {
                    dismiss()
                    onShowCollection()
                }
                .frame(minHeight: 44)
            }
            if item.kind == .cheki {
                Button("继续扫描", systemImage: "camera.viewfinder") {
                    if scanBatch { startScanBatch() }
                    else { openCamera(scan: true) }
                }
                .frame(minHeight: 44)
            }
        }
        .padding(16)
        .kinenCard()
    }

    private var previewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { previewControls }
            VStack(alignment: .leading, spacing: 8) { previewControls }
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(loading || saving)
    }

    private func optionalDetails(video: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !video {
                DisclosureGroup("调整照片", isExpanded: $showsAdjustments) {
                    previewActions.padding(.top, 8)
                    if kind == .cheki && !capturedWithCamera { mediaTypePicker }
                }
                .padding(.vertical, 11)
                Divider()
            }
            DisclosureGroup(note.isEmpty ? "添加回忆" : "回忆", isExpanded: $showsMemory) {
                TextField("写下当时的回忆", text: $note, axis: .vertical)
                    .lineLimit(2...8)
                    .padding(.top, 8)
            }
            .padding(.vertical, 11)
            if !library.snapshot.entries.isEmpty {
                Divider()
                Picker("关联笔记", selection: $destinationID) {
                    Text("不关联").tag(nil as UUID?)
                    ForEach(library.snapshot.entries) { entry in
                        Text(entry.title).tag(Optional(entry.id))
                    }
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .kinenCard(radius: 16)
    }

    @ViewBuilder private var previewControls: some View {
        if kind == .cheki && (correction != nil || !imageAdjustments.isNeutral) {
            Button(showOriginal ? "看处理后的照片" : "看原图", systemImage: "rectangle.split.2x1") {
                showOriginal.toggle()
            }
        }
        if kind == .cheki {
            Button("调整四角", systemImage: "crop") { cropping = true }
        }
        Button("旋转", systemImage: "rotate.right") {
            quarterTurns = (quarterTurns + 1) % 4
            if scanBatch { stashActiveScan() }
        }
    }

    private func preview(_ file: ImportFile) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(Color.kinenPaper)
            if file.isVideo {
                VideoTile(url: file.url)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("视频预览")
            } else {
                Button {
                    inspectingPhoto = true
                } label: {
                    Group {
                        if kind == .cheki && !showOriginal && !imageAdjustments.isNeutral {
                            ChekiAdjustedPreview(source: correction?.source ?? file.url, values: imageAdjustments,
                                                 quarterTurns: quarterTurns)
                        } else {
                            AssetImage(url: kind == .cheki && !showOriginal ? correction?.source ?? file.url : file.url,
                                       maxPixels: 1200, icon: "photo", quarterTurns: quarterTurns)
                        }
                    }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.17), radius: 8, y: 4)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.footnote.weight(.semibold))
                                .padding(8)
                                .background(Color.kinenCanvas, in: Circle())
                                .padding(10)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind == .cheki ? "全屏检查拍立得" : "全屏查看照片")
            }
        }
        .frame(height: kind == .cheki ? 215 : 300)
        .id(file.url)
    }

    private var recordingCard: some View {
        card(kind == .cheki ? "拍摄信息" : "媒体信息", icon: "calendar") {
            if !capturedWithCamera { mediaTypePicker }
            if kind != .cheki { Toggle("知道拍摄日期", isOn: $knowsDate) }
            if kind == .cheki || knowsDate {
                DatePicker("拍摄日期", selection: $date, displayedComponents: .date)
            }
        }
    }

    private var mediaTypePicker: some View {
        Picker("类型", selection: $kind) {
            ForEach(MediaKind.allCases.filter { ($0 == .video) == (source?.isVideo == true) }) {
                Text($0.title).tag($0)
            }
        }
        .pickerStyle(.menu)
    }

    private var subjectCard: some View {
        VStack(spacing: 2) {
            ChekiSubjectPicker(library: library, subject: $subject, openRequest: subjectPickerRequest)
            Divider()
            DatePicker("拍摄日期", selection: $date, displayedComponents: .date)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .kinenCard(radius: 16)
    }

    private var membersCard: some View {
        card("成员", icon: "person.crop.circle") {
            ForEach(library.snapshot.members.filter { !$0.archived || memberIds.contains($0.id) }) { member in
                Toggle(isOn: Binding(
                    get: { memberIds.contains(member.id) },
                    set: { if $0 { memberIds.insert(member.id) } else { memberIds.remove(member.id) } }
                )) {
                    MemberProfileRow(member: member)
                }
            }
            Button("新增成员", systemImage: "person.badge.plus") { addingMember = true }
                .buttonStyle(.bordered)
        }
    }

    private func card<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kinenPaper, in: RoundedRectangle(cornerRadius: 20))
    }

    private func replaceSource(_ file: ImportFile) {
        source?.remove()
        correction?.remove()
        correction = nil
        imageAdjustments = .init()
        source = file
        savedItem = nil
        showOriginal = false
        showsAdjustments = false
        quarterTurns = 0
    }

    private func advanceBatch() {
        guard !pending.isEmpty else { return }
        batchProgress += 1
        loadBatchItem(pending.removeFirst())
    }

    private func loadBatchItem(_ next: PhotosPickerItem) {
        loading = true
        errorMessage = nil
        failedPhoto = nil
        Task {
            do {
                guard let file = try await next.loadTransferable(type: ImportFile.self) else {
                    throw LibraryError.invalidAsset
                }
                replaceSource(file)
                capturedWithCamera = false
                if !copyDetails || file.isVideo || kind == .video {
                    kind = file.isVideo ? .video : .photo
                }
            } catch {
                failedPhoto = next
                errorMessage = "第 \(batchProgress) 项读取失败。\(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func save() {
        guard let source else { return }
        let captureDate = kind == .cheki || knowsDate ? LocalDay.string(from: date) : nil
        let members = Array(memberIds)
        let mediaKind = kind
        let selectedSubject = subject
        let editedNote = note
        let turns = quarterTurns
        let correction = correction
        let adjustments = mediaKind == .cheki ? imageAdjustments : ChekiAdjustments()
        let target = destinationID
        saving = true
        errorMessage = nil
        Task {
            do {
                let enhanced = try await adjustments.export(at: correction?.source ?? source.url)
                defer { if let enhanced { try? FileManager.default.removeItem(at: enhanced) } }
                let item = try await library.store.importMedia(from: source.url, filename: source.filename,
                                                    mimeType: source.mimeType, kind: mediaKind,
                                                    captureDate: captureDate, memberIds: members,
                                                    chekiSubject: selectedSubject, note: editedNote, quarterTurns: turns,
                                                    corrected: correction.map { ($0.source, $0.corners) }, enhanced: enhanced.map { ($0, adjustments) }, attachTo: target)
                if item.kind == .cheki { library.rememberChekiSubject(selectedSubject) }
                source.remove()
                correction?.remove()
                self.source = nil
                self.correction = nil
                savedItem = item
                await library.reload()
                if !pending.isEmpty {
                    note = ""
                    if !copyDetails {
                        subject = nil
                        memberIds = []
                        date = .now
                        knowsDate = true
                        destinationID = entry?.id
                    }
                    advanceBatch()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}

struct ChekiSubjectPicker: View {
    let library: AppLibrary
    @Binding var subject: ChekiSubject?
    var openRequest = 0

    @State private var choosing = false
    @State private var searchText = ""

    var body: some View {
        Button {
            searchText = ""
            choosing = true
        } label: {
            HStack(spacing: 10) {
                if case let .member(id) = subject,
                   let member = library.snapshot.membersByID[id] {
                    MemberProfileRow(member: member)
                } else if case let .group(id) = subject,
                          let group = library.snapshot.groupsByID[id] {
                    Label(group.name, systemImage: "person.3")
                } else {
                    Text("选择成员或团体")
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: openRequest) { _, _ in
            searchText = ""
            choosing = true
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                let query = LibraryQuery(searchText)
                let recent = query.isEmpty ? library.recentChekiSubjects() : []
                let recentIDs = Set(recent)
                let members = library.snapshot.members.filter {
                    !recentIDs.contains(.member($0.id)) &&
                        (!$0.archived || subject == .member($0.id)) &&
                        query.matches([$0.name] + $0.aliases)
                }
                let groups = library.snapshot.groups.filter {
                    !recentIDs.contains(.group($0.id)) && query.matches([$0.name])
                }
                List {
                    if !recent.isEmpty {
                        Section("最近使用") {
                            ForEach(recent, id: \.self) { value in
                                option(value) { subjectLabel(value) }
                            }
                        }
                    }
                    Section {
                        NavigationLink {
                            QuickChekiSubjectEditor(library: library, isGroup: false, initialName: searchText) { select($0) }
                        } label: {
                            Label("新建成员", systemImage: "person.badge.plus")
                        }
                        NavigationLink {
                            QuickChekiSubjectEditor(library: library, isGroup: true, initialName: searchText) { select($0) }
                        } label: {
                            Label("新建团体", systemImage: "person.3")
                        }
                    }
                    if !members.isEmpty {
                        Section("成员") {
                            ForEach(members) { member in
                                option(.member(member.id)) { MemberProfileRow(member: member) }
                            }
                        }
                    }
                    if !groups.isEmpty {
                        Section("团体") {
                            ForEach(groups) { group in
                                option(.group(group.id)) { Label(group.name, systemImage: "person.3") }
                            }
                        }
                    }
                }
                .kinenListStyle()
                .navigationTitle("选择归属")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "搜索成员或团体")
                .toolbar { Button("取消") { choosing = false } }
            }
        }
    }

    private func select(_ value: ChekiSubject) {
        subject = value
        choosing = false
    }

    @ViewBuilder
    private func subjectLabel(_ value: ChekiSubject) -> some View {
        switch value {
        case .member(let id):
            if let member = library.snapshot.membersByID[id] { MemberProfileRow(member: member) }
        case .group(let id):
            if let group = library.snapshot.groupsByID[id] { Label(group.name, systemImage: "person.3") }
        }
    }

    private func option<Value: View>(_ value: ChekiSubject, @ViewBuilder label: () -> Value) -> some View {
        Button {
            select(value)
        } label: {
            HStack {
                label()
                Spacer()
                if value == subject { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(value == subject ? .isSelected : [])
    }

}

private struct QuickChekiSubjectEditor: View {
    let library: AppLibrary
    let isGroup: Bool
    let onSave: (ChekiSubject) -> Void

    @State private var name: String
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focusesName: Bool

    init(library: AppLibrary, isGroup: Bool, initialName: String, onSave: @escaping (ChekiSubject) -> Void) {
        self.library = library
        self.isGroup = isGroup
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            TextField(isGroup ? "团体名称" : "成员姓名", text: $name)
                .focused($focusesName)
                .submitLabel(.done)
                .onSubmit(save)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Color.kinenMuted)
            }
        }
        .kinenListStyle()
        .navigationTitle(isGroup ? "新建团体" : "新建成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存并选中", action: save).disabled(!canSave)
            }
        }
        .task { focusesName = true }
    }

    private var canSave: Bool { !saving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func save() {
        guard canSave else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                let subject: ChekiSubject
                if isGroup {
                    subject = .group(try await library.store.addGroup(name: value).id)
                } else {
                    subject = .member(try await library.store.addMember(name: value).id)
                }
                await library.reload()
                onSave(subject)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ImportFile: Transferable {
    let url: URL
    let filename: String
    let mimeType: String
    let isVideo: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try copy($0.file, video: false) }
        FileRepresentation(importedContentType: .movie) { try copy($0.file, video: true) }
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    fileprivate static func copy(_ source: URL, video: Bool) throws -> Self {
        let suffix = source.pathExtension
        let target = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: target)
        let fallback = video ? "video/quicktime" : "application/octet-stream"
        return Self(url: target, filename: source.lastPathComponent,
                    mimeType: UTType(filenameExtension: suffix)?.preferredMIMEType ?? fallback, isVideo: video)
    }
}

private struct LibraryCamera: UIViewControllerRepresentable {
    let finished: (Result<ImportFile?, Error>) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = UIImagePickerController.availableMediaTypes(for: .camera) ?? [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (Result<ImportFile?, Error>) -> Void

        init(finished: @escaping (Result<ImportFile?, Error>) -> Void) {
            self.finished = finished
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finished(.success(nil))
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finished(Result {
                if let url = info[.mediaURL] as? URL {
                    return try ImportFile.copy(url, video: true)
                }
                if let url = info[.imageURL] as? URL {
                    return try ImportFile.copy(url, video: false)
                }
                guard let image = info[.originalImage] as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.94) else { throw LibraryError.invalidAsset }
                let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
                try data.write(to: url, options: .atomic)
                return ImportFile(url: url, filename: "拍摄照片.jpg", mimeType: "image/jpeg", isVideo: false)
            })
        }
    }
}

private struct ScanBatchEditor: View {
    let library: AppLibrary
    let scans: [MediaImportView.ScanDraft]
    let currentAdjustments: ChekiAdjustments
    let apply: (Set<UUID>, ChekiSubject?, Date?, ChekiAdjustments?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var subject: ChekiSubject?
    @State private var date: Date
    @State private var appliesSubject = true
    @State private var appliesDate = true
    @State private var appliesAdjustments = false

    init(library: AppLibrary, scans: [MediaImportView.ScanDraft], initialSubject: ChekiSubject?, initialDate: Date,
         currentAdjustments: ChekiAdjustments, imageOnly: Bool,
         apply: @escaping (Set<UUID>, ChekiSubject?, Date?, ChekiAdjustments?) -> Void) {
        self.library = library
        self.scans = scans
        self.currentAdjustments = currentAdjustments
        self.apply = apply
        _selected = State(initialValue: Set(scans.map(\.id)))
        _subject = State(initialValue: initialSubject)
        _date = State(initialValue: initialDate)
        _appliesSubject = State(initialValue: !imageOnly)
        _appliesDate = State(initialValue: !imageOnly)
        _appliesAdjustments = State(initialValue: imageOnly)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("统一归属", isOn: $appliesSubject)
                    if appliesSubject { ChekiSubjectPicker(library: library, subject: $subject) }
                    Toggle("统一日期", isOn: $appliesDate)
                    if appliesDate { DatePicker("拍摄日期", selection: $date, displayedComponents: .date) }
                    Toggle("套用当前照片的图像调整", isOn: $appliesAdjustments)
                    if appliesAdjustments {
                        Text("套用曝光、对比度、饱和度和减反光强度。各张照片的四角和标记仍可单独调整。")
                            .font(.footnote).foregroundStyle(Color.kinenMuted)
                    }
                } header: { Text("填写选中的照片") }
                Section {
                    Button(selected.count == scans.count ? "取消全选" : "全选") {
                        selected = selected.count == scans.count ? [] : Set(scans.map(\.id))
                    }
                    ForEach(Array(scans.enumerated()), id: \.element.id) { index, draft in
                        Toggle(isOn: Binding(
                            get: { selected.contains(draft.id) },
                            set: { if $0 { selected.insert(draft.id) } else { selected.remove(draft.id) } }
                        )) {
                            HStack(spacing: 12) {
                                AssetImage(url: draft.correction?.source ?? draft.file.url, maxPixels: 160,
                                           icon: "photo", quarterTurns: draft.turns)
                                    .frame(width: 45, height: 54)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("第 \(index + 1) 张")
                                    Text("\(subjectName(for: draft)) · \(LocalDay.string(from: draft.date))")
                                        .font(.footnote).foregroundStyle(Color.kinenMuted)
                                }
                            }
                        }
                    }
                } header: { Text("已选 \(selected.count) 张") }
            }
            .kinenListStyle()
            .navigationTitle("批量填写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        apply(selected, appliesSubject ? subject : nil, appliesDate ? date : nil,
                              appliesAdjustments ? currentAdjustments : nil)
                        dismiss()
                    }
                    .disabled(selected.isEmpty || (!appliesSubject && !appliesDate && !appliesAdjustments) || (appliesSubject && subject == nil))
                }
            }
        }
    }

    private func subjectName(for draft: MediaImportView.ScanDraft) -> String {
        switch draft.subject {
        case .member(let id): library.snapshot.membersByID[id]?.name ?? "未指定成员"
        case .group(let id): library.snapshot.groupsByID[id]?.name ?? "未指定团体"
        case nil: "待填归属"
        }
    }
}
