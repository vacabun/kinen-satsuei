import AVFoundation
import CoreImage
import KinenCore
import SwiftUI
import Vision

struct ChekiCameraView: View {
    @Binding var autoCapture: Bool
    let onCancel: () -> Void
    var continuousCount: Int? = nil
    var preparingCapture = false
    var onReview: (() -> Void)? = nil
    var onStartContinuous: (() -> Void)? = nil
    let onCapture: (ChekiCapturedPhoto) -> Void

    @StateObject private var camera = ChekiCamera()
    @State private var visible = false
    @State private var stabilityProgress = 0.0
    @State private var stability = ChekiAutoCapture()
    @State private var rearm = ChekiBatchRearm()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session)
                .overlay {
                    if let frame = camera.detection.outline {
                        let outline = Outline(frame: frame)
                        outline.stroke(.black.opacity(0.75), style: StrokeStyle(lineWidth: 9, lineJoin: .round))
                        outline.stroke(.white, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                    } else if camera.ready && !camera.capturing {
                        GeometryReader { geometry in
                            let width = min(geometry.size.width * 0.62, geometry.size.height * 0.41)
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(.white.opacity(0.48), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                                .frame(width: width, height: width * 1.5)
                                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.46)
                        }
                    }
                }
                .accessibilityHidden(true)
                .clipped()
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("关闭相机")
                    .disabled(preparingCapture)
                    Spacer()
                    Picker("拍摄方式", selection: $autoCapture) {
                        Text("手动").tag(false)
                        Text("自动").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 164)
                    .padding(4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(camera.capturing || preparingCapture)
                    Spacer()
                    Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
                }
                Spacer()
                Text(camera.errorMessage ?? guidance)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.65), in: Capsule())
                    .accessibilityAddTraits(.updatesFrequently)


                Button { takePhoto() } label: {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(stabilityProgress > 0 ? 0.45 : 1), lineWidth: 3)
                        if stabilityProgress > 0 {
                            Circle().trim(from: 0, to: stabilityProgress)
                                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(2)
                        }
                        if camera.capturing || preparingCapture {
                            ProgressView().tint(.white)
                        } else {
                            Circle().fill(.white).padding(8)
                        }
                    }
                    .frame(width: 76, height: 76)
                }
                .accessibilityLabel("拍摄")
                .disabled(!camera.ready || camera.capturing || preparingCapture)
                .opacity(camera.ready ? 1 : 0.45)
                .padding(.top, 8)
                if let continuousCount, let onReview {
                    Button(action: onReview) {
                        Label(continuousCount == 0 ? "检查照片" : "检查 \(continuousCount) 张", systemImage: "square.stack")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .disabled(continuousCount == 0 || preparingCapture || camera.capturing)
                    .opacity(continuousCount == 0 ? 0.5 : 1)
                } else if let onStartContinuous {
                    Button {
                        resetStability()
                        onStartContinuous()
                    } label: {
                        Label("连续拍", systemImage: "square.stack")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .disabled(!camera.ready || preparingCapture || camera.capturing)
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .preferredColorScheme(.dark)
        .onChange(of: autoCapture) { _, _ in resetStability() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetStability() }
        }
        .onReceive(camera.$detection) { updateAutoCapture(with: $0) }
        .onAppear {
            visible = true
            camera.start()
        }
        .onDisappear {
            visible = false
            camera.stop()
        }
    }

    private var guidance: String {
        if !camera.ready { return "正在启动相机…" }
        if camera.capturing || preparingCapture { return "正在处理照片…" }
        if continuousCount != nil && autoCapture && rearm.waiting {
            return "移开上一张，或按快门继续"
        }
        switch camera.detection.framing {
        case .ready: return autoCapture ? "保持稳定，即将拍摄" : "已识别相纸边缘，按快门拍摄"
        case .tooSmall: return "再靠近一点，让相纸占据更多画面"
        case .nearEdge: return "稍微退远，让相纸四周留出一点空间"
        case .wrongShape: return "对准相纸外框，适当放平手机"
        case .multiple: return "一次只对准一张拍立得"
        case .noOutline: return "让拍立得的四个角都进入画面"
        }
    }

    private func takePhoto(matching outline: ChekiOutline? = nil) {
        resetStability()
        camera.capture(matching: outline) { data in
            guard visible else { return }
            if continuousCount != nil { rearm.didCapture() }
            onCapture(data)
        }
    }

    private func updateAutoCapture(with frame: ChekiDetection) {
        guard autoCapture, camera.ready, visible, scenePhase == .active,
              !camera.capturing, camera.errorMessage == nil,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.42 else {
            resetStability()
            return
        }
        if continuousCount != nil {
            let armed = rearm.observe(isEmpty: frame.framing == .noOutline, at: frame.timestamp)
            if !armed || preparingCapture {
                resetStability()
                return
            }
        }
        let outline = frame.framing == .ready ? frame.outline : nil
        stabilityProgress = stability.progress(for: outline?.quad, at: frame.timestamp)
        if stabilityProgress >= 1, let outline { takePhoto(matching: outline) }
    }

    private func resetStability() {
        stability.reset()
        stabilityProgress = 0
    }

}

private struct Outline: Shape {
    let frame: ChekiOutline

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / frame.size.width, rect.height / frame.size.height)
        let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
        let offsetX = rect.midX - size.width / 2
        let offsetY = rect.midY - size.height / 2
        let points = frame.corners.map {
            CGPoint(x: offsetX + $0.x * size.width, y: offsetY + (1 - $0.y) * size.height)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

private struct ChekiOutline {
    let quad: PhotoQuad
    let size: CGSize
    var corners: [CGPoint] { quad.corners.map { CGPoint(x: $0.x, y: $0.y) } }
}

private struct ChekiDetection {
    var outline: ChekiOutline?
    var framing = ChekiFraming.noOutline
    var timestamp = 0.0
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspect
        view.preview.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.updateRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        func updateRotation() {
            // Keep the preview and Vision buffers in the same portrait coordinates.
            if let connection = preview.connection, connection.videoRotationAngle != 90,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

private final class ChekiCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var detection = ChekiDetection()
    @Published private(set) var errorMessage: String?

    private let captureQueue = DispatchQueue(label: "kinen.camera.session", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "kinen.camera.preview", qos: .userInitiated)
    private let photos = AVCapturePhotoOutput()
    private lazy var imageContext = CIContext()
    private var configured = false
    private var active = false
    private var lastDetectionTime = -Double.infinity
    private var photoCompletion: ((Data?) -> Void)?

    func start() {
        active = true
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if granted { self.startSession() }
                    else { self.showPermissionError() }
                }
            }
        default:
            showPermissionError()
        }
    }

    func stop() {
        active = false
        ready = false
        detection = ChekiDetection()
        captureQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture(matching outline: ChekiOutline? = nil, completion: @escaping (ChekiCapturedPhoto) -> Void) {
        guard ready, !capturing else { return }
        capturing = true
        errorMessage = nil
        let detected = detection.framing == .ready ? detection.outline : nil
        let expectedCorners = (outline ?? detected)?.corners
        captureQueue.async {
            self.photoCompletion = { data in
                let result = data.map { self.correctedPhoto($0, matching: expectedCorners) }
                DispatchQueue.main.async {
                    guard self.active else { return }
                    self.capturing = false
                    if let result { completion(result) }
                    else { self.errorMessage = "未能拍摄，请再试一次。" }
                }
            }
            self.photos.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]),
                                     delegate: self)
        }
    }

    private func showPermissionError() {
        errorMessage = "请在 iPhone 设置中允许「記念撮影」使用相机。"
    }

    private func startSession() {
        captureQueue.async {
            if !self.configured { self.configured = self.configureSession() }
            if self.configured && !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                guard self.active else { return }
                self.ready = running
                if !running { self.errorMessage = "无法启动后置相机。" }
            }
        }
    }

    private func configureSession() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        let frames = AVCaptureVideoDataOutput()
        frames.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        guard session.canAddOutput(photos) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(photos)
        guard session.canAddOutput(frames) else {
            session.removeOutput(photos)
            session.removeInput(input)
            return false
        }
        session.addOutput(frames)
        frames.setSampleBufferDelegate(self, queue: detectionQueue)
        for connection in [frames.connection(with: .video), photos.connection(with: .video)].compactMap({ $0 })
            where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastDetectionTime >= 0.15,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetectionTime = time
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let candidates = Self.rectangles(in: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up))
        let input = candidates.compactMap { rectangle -> ChekiFraming.Candidate? in
            let points = Self.corners(of: rectangle).map { PhotoPoint(x: $0.x, y: $0.y) }
            guard let quad = PhotoQuad(corners: points) else { return nil }
            return ChekiFraming.Candidate(quad: quad, confidence: Double(rectangle.confidence))
        }
        let selection = ChekiFraming.select(input, imageAspect: size.width / size.height)
        let outline = selection.0.map { ChekiOutline(quad: $0, size: size) }
        let frame = ChekiDetection(outline: outline, framing: selection.1, timestamp: time)
        DispatchQueue.main.async {
            if self.active && !self.capturing { self.detection = frame }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        finishCapture(with: data)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if error != nil { finishCapture(with: nil) }
    }

    private func finishCapture(with data: Data?) {
        captureQueue.async {
            let completion = self.photoCompletion
            self.photoCompletion = nil
            completion?(data)
        }
    }

    private func correctedPhoto(_ data: Data, matching expected: [CGPoint]?) -> ChekiCapturedPhoto {
        let original = ChekiCapturedPhoto(original: data, correction: nil)
        guard let expected, let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return original
        }
        let candidates = Self.rectangles(in: VNImageRequestHandler(ciImage: image, orientation: .up))
        func distance(_ rectangle: VNRectangleObservation) -> CGFloat {
            zip(Self.corners(of: rectangle), expected).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
        }
        guard let match = candidates.min(by: { distance($0) < distance($1) }), distance(match) < 0.18,
              let corners = PhotoQuad(corners: Self.corners(of: match).map { PhotoPoint(x: $0.x, y: $0.y) }),
              let corrected = ChekiImageCorrection.jpeg(image: image, corners: corners, context: imageContext) else {
            return original
        }
        return ChekiCapturedPhoto(original: data, correction: (corrected, corners))
    }

    private static func rectangles(in handler: VNImageRequestHandler) -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 1
        request.minimumSize = 0.16
        request.minimumConfidence = 0.65
        request.maximumObservations = 6
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private static func corners(of rectangle: VNRectangleObservation) -> [CGPoint] {
        [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
    }

}
