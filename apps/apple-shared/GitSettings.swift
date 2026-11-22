import KinenCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol GitSettingsLibrary: AnyObject {
    var store: LibraryStore { get }
    func reload() async
    func importBackup(from source: URL, name: String?,
                      remote: (connectionID: String, revision: GitRevision)?) async throws -> (id: UUID, summary: BackupSummary)
    func switchLibrary(to id: UUID?) async throws
}

struct GitSyncSettings<Model: GitSettingsLibrary>: View {
    let library: Model

    @State private var remoteText = ""
    @State private var branch = "main"
    @State private var mediaScope = SyncMediaScope.metadataOnly
    @State private var remotePreview: RemotePreview?
    @State private var message: String?
    @State private var status: LibrarySyncStatus?
    @State private var unsyncedMetadata: Bool?
    @State private var showsConnection = false
    @State private var fingerprint: GitSSHHostPin?
    @State private var fingerprintEndpoint: String?
    @State private var previousFingerprint: GitSSHHostPin?
    @State private var working = false
    @State private var conflicts: [LibrarySyncConflict] = []
    @State private var showingConflicts = false
    @State private var conflictChoices: [String: SyncConflictChoice] = [:]
    @State private var visible = false
    private let keychain = GitSSHCredentialStore()

    private enum Action { case check, synchronize, preview }

    private struct RemotePreview {
        let workFolder: URL
        let snapshot: URL
        let remote: URL
        let branch: String
        let revision: GitRevision
        let summary: BackupSummary
        let title: String

        var connectionID: String { remote.absoluteString + "#" + branch }
    }

    private var libraryKey: String { library.store.root.lastPathComponent }
    private var settingsKey: String { "KinenGitSettings." + libraryKey }
    private var pinKey: String { settingsKey + ".fingerprints" }

    var body: some View {
        Form {
            Section("同步状态") {
                if let status {
                    if let unsyncedMetadata {
                        Label(unsyncedMetadata ? "本机有未同步的记录" : "本机记录已同步",
                              systemImage: unsyncedMetadata ? "clock" : "checkmark.circle")
                    }
                    LabeledContent("上次成功同步") {
                        Text(status.syncedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    if let attachments = status.attachments, attachments.notUploaded > 0 {
                        LabeledContent("保留在本机的附件", value: "\(attachments.notUploaded) 项")
                        if attachments.tooLarge > 0 {
                            LabeledContent("超过大小上限", value: "\(attachments.tooLarge) 项")
                        }
                    }
                } else {
                    Text(hasRemote ? "尚未同步" : "目前仅保存在本机")
                        .foregroundStyle(.secondary)
                }
                if working {
                    ProgressView("正在连接 Git 仓库…")
                } else if hasRemote {
                    Button("现在同步", systemImage: "arrow.triangle.2.circlepath") { run(.synchronize) }
                        .fontWeight(.semibold)
                    Button("预览远程备份", systemImage: "tray.and.arrow.down") { run(.preview) }
                } else if !showsConnection {
                    Button("设置 Git 同步", systemImage: "link") { showsConnection = true }
                        .fontWeight(.semibold)
                }
                if !conflicts.isEmpty {
                    Button("查看冲突（\(conflicts.count)）", systemImage: "exclamationmark.circle") {
                        showingConflicts = true
                    }
                }
                if let message { Text(message).font(.footnote).textSelection(.enabled) }
            }
            if hasRemote || showsConnection {
                Section {
                    DisclosureGroup("连接设置", isExpanded: $showsConnection) {
                        TextField("SSH 仓库地址", text: $remoteText).gitField(url: true)
                        TextField("分支", text: $branch).gitField()
                        NavigationLink {
                            GitSSHIdentitySettings(connectionID: libraryKey)
                        } label: {
                            Label("配置 SSH 密钥", systemImage: "key")
                        }
                        Picker("同步范围", selection: $mediaScope) {
                            Text("仅笔记和元数据").tag(SyncMediaScope.metadataOnly)
                            Text("包含照片和视频").tag(SyncMediaScope.includeAttachments)
                        }
                        Text(mediaScope == .metadataOnly
                             ? "恢复时可取回笔记、成员资料和媒体目录。"
                             : "附带照片和视频，单个附件上限 95 MiB。请使用私有仓库。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("检查连接", systemImage: "link") { run(.check) }
                            .disabled(!hasRemote)
                    }
                } footer: {
                    if showsConnection {
                        Text("填写仓库地址，配置密钥并检查连接。首次连接时需要核对服务器指纹。")
                    }
                }
            }
            if let fingerprint {
                Section {
                    if let previousFingerprint {
                        fingerprintValue("原指纹", previousFingerprint.fingerprint)
                    }
                    fingerprintValue(previousFingerprint == nil ? "服务器指纹" : "新指纹", fingerprint.fingerprint)
                    Button(previousFingerprint == nil ? "确认指纹并信任" : "重新核验后信任") { trustHost() }
                    Button("取消", role: .cancel) { clearFingerprint() }
                } header: {
                    Text(previousFingerprint == nil ? "核对 SSH 主机指纹" : "主机指纹已变化")
                } footer: {
                    Text("请先从 Git 服务官方文档或服务器管理员处核对该指纹。")
                }
            }
            if let preview = remotePreview {
                Section("远程资料库预览") {
                    LabeledContent("资料库", value: preview.title)
                    LabeledContent("笔记", value: "\(preview.summary.notes) 篇")
                    LabeledContent("媒体记录", value: "\(preview.summary.media) 项")
                    if preview.summary.missingAssets > 0 {
                        LabeledContent("缺失附件", value: "\(preview.summary.missingAssets) 项")
                    }
                    Button("恢复并打开独立资料库") { restore(preview) }
                    Button("取消预览", role: .cancel) { clearPreview() }
                }
            }

        }
        .disabled(working)
        .gitSettingsForm()
        .navigationTitle("Git 同步")
        .task(id: libraryKey) {
            let settings = UserDefaults.standard.stringArray(forKey: settingsKey) ?? []
            if settings.count == 2 {
                remoteText = settings[0]
                branch = settings[1]
            }
            if let storedScope = UserDefaults.standard.string(forKey: settingsKey + ".mediaScope"),
               let scope = SyncMediaScope(rawValue: storedScope) { mediaScope = scope }
            await refreshStatus(for: library.store)
        }
        .onChange(of: remoteText) { _, _ in
            clearFingerprint()
            clearPreview()
        }
        .onChange(of: branch) { _, _ in
            clearFingerprint()
            clearPreview()
        }
        .onChange(of: mediaScope) { _, scope in
            UserDefaults.standard.set(scope.rawValue, forKey: settingsKey + ".mediaScope")
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            clearPreview()
        }
        .sheet(isPresented: $showingConflicts) {
            NavigationStack {
                List {
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                        conflictSection(conflict)
                    }
                }
                .navigationTitle("同步冲突")
                .gitInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showingConflicts = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("应用并同步") {
                            showingConflicts = false
                            run(.synchronize, resolutions: conflictChoices)
                        }
                        .disabled(!canResolveConflicts || working)
                    }
                }
            }
        }
    }

    private var hasRemote: Bool { !remoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func refreshStatus(for store: LibraryStore) async {
        do {
            let fetched = try await store.syncStatus()
            let changed = try await store.hasUnsyncedMetadata()
            guard library.store === store, !Task.isCancelled else { return }
            status = fetched
            unsyncedMetadata = changed
        } catch {
            if library.store === store && !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func conflictSection(_ conflict: LibrarySyncConflict) -> some View {
        let title = conflict.noteVersions?.local?.title ?? conflict.noteVersions?.remote?.title ??
            collectionName(conflict.collection)
        let fields = conflict.fields.map { fieldName($0) }.joined(separator: "、")
        return Section(title) {
            Text(fields)
                .font(.caption)
                .foregroundStyle(.secondary)
            conflictVersion("本机", note: conflict.noteVersions?.local,
                            record: conflict.localRecord, fields: conflict.fields)
            conflictVersion("远端", note: conflict.noteVersions?.remote,
                            record: conflict.remoteRecord, fields: conflict.fields)
            if conflict.noteVersions?.base != nil || conflict.baseRecord != nil {
                conflictVersion("共同版本", note: conflict.noteVersions?.base,
                                record: conflict.baseRecord, fields: conflict.fields)
            }
            if let token = conflict.resolutionToken {
                Picker("冲突字段保留", selection: Binding<SyncConflictChoice?>(
                    get: { conflictChoices[token] },
                    set: { conflictChoices[token] = $0 }
                )) {
                    Text("请选择").tag(nil as SyncConflictChoice?)
                    Text("本机版本").tag(Optional(SyncConflictChoice.local))
                    Text("远端版本").tag(Optional(SyncConflictChoice.remote))
                }
            } else {
                Text("请先修正笔记或媒体的关联，再重试同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var canResolveConflicts: Bool {
        !conflicts.isEmpty && conflicts.allSatisfy { conflict in
            conflict.resolutionToken.map { conflictChoices[$0] != nil } ?? false
        }
    }

    private func conflictVersion(_ label: String, note: LibraryEntry?, record: Data?, fields: [String]) -> some View {
        DisclosureGroup(label) {
            if let note {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title).font(.headline)
                    LabeledContent("日期", value: note.endDate.map { note.startDate + " 至 " + $0 } ?? note.startDate)
                    if !note.body.isEmpty { Text(note.body).textSelection(.enabled) }
                }
            } else if let record,
                      let data = try? JSONSerialization.jsonObject(with: record) as? [String: Any] {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = data["name"] as? String { Text(name).font(.headline) }
                    ForEach(fields.filter { ["note", "captureDate", "groupId", "memberIds", "kind", "archived", "aliases"].contains($0) },
                            id: \.self) { field in
                        LabeledContent(fieldName(field), value: data[field].map { String(describing: $0) } ?? "未设置")
                    }
                }
            } else {
                Text("这一版本没有该记录。").foregroundStyle(.secondary)
            }
        }
    }

    private func fingerprintValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func fieldName(_ field: String) -> String {
        switch field {
        case "body", "note": "正文或备注"
        case "title": "标题"
        case "kind": "类型"
        case "startDate", "endDate", "captureDate": "日期"
        case "parent": "上级笔记"
        case "media": "关联媒体"
        case "itinerary": "行程"
        case "cover": "封面"
        case "cards": "卡片内容、顺序或锁定状态"
        case "location": "地点"
        case "memberIds": "成员"
        case "groupId": "团体"
        case "name": "名称"
        case "aliases": "别名"
        case "archived": "归档状态"
        case "addition": "新增记录"
        case "deletion": "删除记录"
        default: field
        }
    }

    private func collectionName(_ collection: String) -> String {
        switch collection {
        case "members": "成员记录"
        case "groups": "团体记录"
        case "entries": "笔记"
        default: "媒体记录"
        }
    }

    private func run(_ action: Action, resolutions: [String: SyncConflictChoice] = [:]) {
        working = true
        message = nil
        clearFingerprint()
        clearPreview()
        let store = library.store
        Task {
            defer { working = false }
            do {
                let remote = try remoteURL()
                let targetBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                let endpoint = remote.absoluteString
                let connectionID = endpoint + "#" + targetBranch
                UserDefaults.standard.set([remoteText, targetBranch], forKey: settingsKey)
                guard let stored = try keychain.load(for: libraryKey) else {
                    showsConnection = true
                    message = "请先在「配置 SSH 密钥」中生成或导入密钥，再把公钥添加到远程 Git 服务。"
                    return
                }
                let trusted = (UserDefaults.standard.dictionary(forKey: pinKey)?[endpoint] as? String)
                    .flatMap { try? GitSSHHostPin($0) }
                let credentials = GitSSHCredentials(identity: stored.identity, hostPin: trusted)
                let gitRoot = library.store.root.deletingLastPathComponent()
                    .appending(path: ".git-cache-" + libraryKey)
                let transport = try EmbeddedGitTransport(remote: remote, branch: targetBranch,
                                                         repository: gitRoot, credentials: credentials)
                do {
                    switch action {
                    case .check:
                        let revision = try await transport.fetch()
                        message = revision == nil ? "SSH 连接成功。远程分支尚未初始化。" : "SSH 连接成功，已读取远程分支。"
                    case .synchronize:
                        let result = try await LibrarySync(transport: transport)
                            .synchronize(store: store, connectionID: connectionID, mediaScope: mediaScope,
                                         resolutions: resolutions)
                        switch result {
                        case .applied:
                            conflicts = []
                            conflictChoices = [:]
                            await refreshStatus(for: store)
                            if library.store.root == store.root { await library.reload() }
                            message = "同步成功。"
                        case .conflicts(let found):
                            conflicts = found
                            let tokens = Set(found.compactMap(\.resolutionToken))
                            conflictChoices = conflictChoices.filter { tokens.contains($0.key) }
                            message = resolutions.isEmpty ? "同步暂停。请先查看冲突。" : "仍有冲突，请重新核对版本。"
                        }
                    case .preview:
                        let folder = URL.temporaryDirectory.appending(path: "KinenRemotePreview-\(UUID().uuidString)")
                        let snapshot = folder.appending(path: "library")
                        do {
                            let revision = try await LibrarySync(transport: transport).downloadRemote(at: snapshot)
                            let remoteLibrary = LibraryStore(root: snapshot)
                            let summary = try await remoteLibrary.backupSummary()
                            let title = try await remoteLibrary.libraryTitle()
                            if visible {
                                remotePreview = RemotePreview(workFolder: folder, snapshot: snapshot, remote: remote,
                                                              branch: targetBranch, revision: revision, summary: summary, title: title)
                            } else {
                                try? FileManager.default.removeItem(at: folder)
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: folder)
                            throw error
                        }
                    }
                } catch EmbeddedGitError.untrustedHost(let candidate) {
                    fingerprint = candidate
                    fingerprintEndpoint = endpoint
                } catch EmbeddedGitError.changedHost(let candidate) {
                    previousFingerprint = trusted
                    fingerprint = candidate
                    fingerprintEndpoint = endpoint
                    message = "服务器指纹已变更。请重新核对服务器身份。"
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func restore(_ preview: RemotePreview) {
        let previousLibraryKey = libraryKey
        let scope = mediaScope
        working = true
        remotePreview = nil
        Task {
            defer {
                try? FileManager.default.removeItem(at: preview.workFolder)
                working = false
            }
            do {
                let result = try await library.importBackup(from: preview.snapshot, name: preview.remote.lastPathComponent,
                                                            remote: (preview.connectionID, preview.revision))
                let restoredKey = result.id.uuidString.lowercased()
                let restoredSettings = "KinenGitSettings." + restoredKey
                let endpoint = preview.remote.absoluteString
                UserDefaults.standard.set([endpoint, preview.branch], forKey: restoredSettings)
                UserDefaults.standard.set(scope.rawValue, forKey: restoredSettings + ".mediaScope")
                if let pin = UserDefaults.standard.dictionary(forKey: pinKey)?[endpoint] as? String {
                    UserDefaults.standard.set([endpoint: pin], forKey: restoredSettings + ".fingerprints")
                }
                if let credentials = try keychain.load(for: previousLibraryKey) {
                    try keychain.save(credentials, for: restoredKey)
                }
                clearPreview()
                try await library.switchLibrary(to: result.id)
                await refreshStatus(for: library.store)
                message = "已打开恢复的资料库。"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func clearPreview() {
        guard let preview = remotePreview else { return }
        remotePreview = nil
        try? FileManager.default.removeItem(at: preview.workFolder)
    }

    private func trustHost() {
        guard let fingerprint, let endpoint = fingerprintEndpoint else { return }
        var pins = UserDefaults.standard.dictionary(forKey: pinKey) as? [String: String] ?? [:]
        pins[endpoint] = fingerprint.fingerprint
        UserDefaults.standard.set(pins, forKey: pinKey)
        clearFingerprint()
        message = "已保存指纹，可以再次检查连接或同步。"
    }

    private func clearFingerprint() {
        fingerprint = nil
        fingerprintEndpoint = nil
        previousFingerprint = nil
    }

    private func remoteURL() throws -> URL {
        let address = remoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if !address.contains("://"), let separator = address.firstIndex(of: ":"), address[..<separator].contains("@") {
            let path = address[address.index(after: separator)...]
            normalized = "ssh://" + address[..<separator] + (path.hasPrefix("/") ? "" : "/") + path
        } else {
            normalized = address
        }
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "ssh",
              let host = url.host, !host.isEmpty, !url.path.isEmpty,
              url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.contains("'"),
              url.path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw GitTransportError.invalidRemote
        }
        return url
    }
}

struct GitSSHIdentitySettings: View {
    let connectionID: String

    @State private var credentials: GitSSHCredentials?
    @State private var importPublicKey = ""
    @State private var importPrivateKey = ""
    @State private var passphrase = ""
    @State private var readingPrivateKey = false
    @State private var confirmingReplacement = false
    @State private var errorMessage: String?
    private let keychain = GitSSHCredentialStore()

    var body: some View {
        Form {
            Section("公钥") {
                if let credentials {
                    Text(verbatim: credentials.identity.publicKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    ShareLink(item: credentials.identity.publicKey) {
                        Label("分享公钥", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("当前资料库还没有 SSH 密钥。").foregroundStyle(.secondary)
                }

                Button("生成 Ed25519 密钥", systemImage: "key") {
                    if credentials != nil { confirmingReplacement = true }
                    else { generateIdentity() }
                }
            }
            Section {
                TextField("粘贴公钥", text: $importPublicKey, axis: .vertical)
                    .gitField()
                Button("选择 OpenSSH 私钥文件", systemImage: "doc") { readingPrivateKey = true }
                if !importPrivateKey.isEmpty {
                    Label("已选择私钥", systemImage: "checkmark")
                }
                SecureField("私钥口令（选填）", text: $passphrase)
                Button("保存导入的密钥") { saveImportedIdentity() }
                    .disabled(importPublicKey.isEmpty || importPrivateKey.isEmpty)
            } header: {
                Text("导入已有密钥")
            } footer: {
                Text("私钥和口令保存在本机钥匙串。保存导入的密钥会替换此资料库当前使用的密钥。")
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.circle").font(.footnote) }
            }
        }
        .gitSettingsForm()
        .navigationTitle("SSH 密钥")
        .task {
            do { credentials = try keychain.load(for: connectionID) }
            catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $readingPrivateKey, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 65_537) ?? Data()
                guard data.count <= 65_536, let key = String(data: data, encoding: .utf8) else {
                    throw GitSSHError.invalidIdentity
                }
                importPrivateKey = key
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("替换当前 SSH 密钥？", isPresented: $confirmingReplacement, titleVisibility: .visible) {
            Button("生成并替换", role: .destructive) { generateIdentity() }
            Button("取消", role: .cancel) {}
        }
    }

    private func generateIdentity() {
        do { try save(GitSSHIdentity.generate()) }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveImportedIdentity() {
        do {
            try save(GitSSHIdentity(publicKey: importPublicKey, privateKey: importPrivateKey, passphrase: passphrase))
            importPublicKey = ""
            importPrivateKey = ""
            passphrase = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ identity: GitSSHIdentity) throws {
        let saved = GitSSHCredentials(identity: identity, hostPin: credentials?.hostPin)
        try keychain.save(saved, for: connectionID)
        credentials = saved
        errorMessage = nil
    }
}


private extension View {
    @ViewBuilder func gitField(url: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .default)
        #else
        autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func gitSettingsForm() -> some View {
        #if os(iOS)
        kinenListStyle()
        #else
        formStyle(.grouped)
        #endif
    }

    @ViewBuilder func gitInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
