import CoreTransferable
import KinenCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct MediaImportView: View {
    let library: AppLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var source: ImportFile?
    @State private var scan: UIImage?
    @State private var scanning = false
    @State private var kind = MediaKind.photo
    @State private var knowsDate = true
    @State private var date = Date.now
    @State private var memberIds: Set<UUID> = []
    @State private var loading = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("来源") {
                    PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    .disabled(loading || saving)
                    Button("扫描拍立得", systemImage: "viewfinder") { scanning = true }
                        .disabled(loading || saving || !VNDocumentCameraViewController.isSupported)
                    if loading { ProgressView("正在读取媒体") }
                    if let source { Text(source.filename).font(.caption).foregroundStyle(.secondary) }
                    if let scan {
                        Image(uiImage: scan).resizable().scaledToFit().frame(maxHeight: 180)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("记录") {
                    Picker("类型", selection: $kind) {
                        ForEach(MediaKind.allCases.filter { ($0 == .video) == (source?.isVideo == true) }) {
                            Text($0.title).tag($0)
                        }
                    }
                    Toggle("知道拍摄日期", isOn: $knowsDate)
                    if knowsDate { DatePicker("拍摄日期", selection: $date, displayedComponents: .date) }
                }
                if !library.snapshot.members.isEmpty {
                    Section("成员") {
                        ForEach(library.snapshot.members) { member in
                            Toggle(member.name, isOn: Binding(
                                get: { memberIds.contains(member.id) },
                                set: { if $0 { memberIds.insert(member.id) } else { memberIds.remove(member.id) } }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("添加媒体")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") {
                        source?.remove()
                        dismiss()
                    }
                    .disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(loading || saving || source == nil)
                }
            }
            .interactiveDismissDisabled(source != nil || saving || loading)
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
                    scan = nil
                    kind = file.isVideo ? .video : .photo
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { result in
                    scanning = false
                    guard let result else { return }
                    do {
                        let image = try result.get()
                        guard let data = image.jpegData(compressionQuality: 0.94) else { throw LibraryError.invalidAsset }
                        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
                        try data.write(to: url, options: .atomic)
                        replaceSource(ImportFile(url: url, filename: "扫描拍立得.jpg", mimeType: "image/jpeg", isVideo: false))
                        scan = image
                        photo = nil
                        kind = .cheki
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func replaceSource(_ file: ImportFile) {
        source?.remove()
        source = file
    }

    private func save() {
        guard let source else { return }
        let captureDate = knowsDate ? LocalDay.string(from: date) : nil
        let members = Array(memberIds)
        let mediaKind = kind
        saving = true
        errorMessage = nil
        Task {
            do {
                try await library.store.importMedia(from: source.url, filename: source.filename,
                                                    mimeType: source.mimeType, kind: mediaKind,
                                                    captureDate: captureDate, memberIds: members)
                source.remove()
                await library.reload()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
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

    private static func copy(_ source: URL, video: Bool) throws -> Self {
        let suffix = source.pathExtension
        let target = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: target)
        let fallback = video ? "video/quicktime" : "application/octet-stream"
        return Self(url: target, filename: source.lastPathComponent,
                    mimeType: UTType(filenameExtension: suffix)?.preferredMIMEType ?? fallback, isVideo: video)
    }
}

private struct DocumentScanner: UIViewControllerRepresentable {
    var completion: (Result<UIImage, Error>?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<UIImage, Error>?) -> Void

        init(completion: @escaping (Result<UIImage, Error>?) -> Void) { self.completion = completion }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { completion(.failure(LibraryError.invalidAsset)); return }
            completion(.success(scan.imageOfPage(at: 0)))
        }
    }
}
