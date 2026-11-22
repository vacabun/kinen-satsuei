import AVFoundation
import KinenCore
import SwiftUI
import UIKit

struct PhotoInspectionView: View {
    let original: URL
    let corrected: URL?
    let quarterTurns: Int
    @Binding var showsOriginal: Bool
    var position: String? = nil
    var previous: (() -> Void)? = nil
    var next: (() -> Void)? = nil
    var showDetails: (() -> Void)? = nil
    var controlsVisibility: Binding<Bool>? = nil
    var quickPreview: CGImage? = nil
    var sharePhoto: (() -> Void)? = nil
    var adjustments: ChekiAdjustments? = nil
    var processedLabel = "校正图"

    @Environment(\.dismiss) private var dismiss
    @State private var originalImage: CGImage?
    @State private var correctedImage: CGImage?
    @State private var originalLoaded = false
    @State private var correctedLoaded = false
    @State private var zoomCommand: PhotoZoomCommand?
    @State private var localControlsVisible = true

    private var controls: Binding<Bool> { controlsVisibility ?? $localControlsVisible }

    private func toggleControls() {
        controls.wrappedValue.toggle()
    }

    private var viewingOriginal: Bool { showsOriginal || corrected == nil }
    private var currentImage: CGImage? {
        if viewingOriginal { return originalImage ?? (corrected == nil ? quickPreview : nil) }
        return correctedImage ?? quickPreview
    }
    private var loaded: Bool { viewingOriginal ? originalLoaded : correctedLoaded }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ZoomableInspectionImage(image: currentImage, quarterTurns: quarterTurns, command: zoomCommand,
                                        previous: previous, next: next, toggleControls: toggleControls)
                    .accessibilityAction(named: Text(controls.wrappedValue ? "隐藏控件" : "显示控件"), toggleControls)
                if currentImage == nil {
                    if loaded {
                        ContentUnavailableView("无法读取照片", systemImage: "photo")
                    } else {
                        ProgressView("正在读取照片…").tint(.white)
                    }
                }
            }
            .navigationTitle("检查照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(controls.wrappedValue ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if let showDetails {
                        Button("媒体详情", systemImage: "info.circle", action: showDetails)
                    }
                    if let sharePhoto {
                        Button("分享当前照片", systemImage: "square.and.arrow.up", action: sharePhoto)
                    }
                    Menu("缩放", systemImage: "magnifyingglass") {
                        Button("放大", systemImage: "plus.magnifyingglass") { zoomCommand = .init(reset: false) }
                        Button("还原大小", systemImage: "arrow.up.left.and.arrow.down.right") { zoomCommand = .init(reset: true) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if controls.wrappedValue, let position {
                    HStack {
                        Button("上一张", systemImage: "chevron.left") { previous?() }
                            .disabled(previous == nil)
                        Spacer()
                        Text(position).monospacedDigit()
                        Spacer()
                        Button("下一张", systemImage: "chevron.right") { next?() }
                            .disabled(next == nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.black)
                }
                if controls.wrappedValue, corrected != nil {
                    Picker("照片版本", selection: $showsOriginal) {
                        Text(adjustments == nil ? processedLabel : "调整图").tag(false)
                        Text("原图").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: original) {
            let image = await ThumbnailCache.shared.image(at: original, fallback: nil, pixels: 2400, contentID: nil)
            guard !Task.isCancelled else { return }
            originalImage = image
            originalLoaded = true
        }
        .task(id: corrected) {
            guard let corrected else { return }
            let image: CGImage?
            if let adjustments {
                image = await LibraryWork.run { adjustments.preview(at: corrected, pixels: 2400) }
            } else {
                image = await ThumbnailCache.shared.image(at: corrected, fallback: nil, pixels: 2400, contentID: nil)
            }
            guard !Task.isCancelled else { return }
            correctedImage = image
            correctedLoaded = true
        }
    }
}

struct PhotoZoomCommand: Equatable {
    let id = UUID()
    let reset: Bool
}

struct ZoomableInspectionImage: UIViewRepresentable {
    let image: CGImage?
    let quarterTurns: Int
    let command: PhotoZoomCommand?
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let toggleControls: () -> Void
    var markPhoto: ((CGPoint) -> Void)? = nil
    var allowsParentScroll = false

    func makeUIView(context: Context) -> ZoomView { ZoomView(frame: .zero) }

    func updateUIView(_ view: ZoomView, context: Context) {
        let directions: [UIImage.Orientation] = [.up, .right, .down, .left]
        let direction = directions[(quarterTurns % 4 + 4) % 4]
        view.photo.image = image.map { UIImage(cgImage: $0, scale: 1, orientation: direction) }
        view.onPrevious = previous
        view.onNext = next
        view.onToggleControls = toggleControls
        view.onMarkPhoto = markPhoto
        view.allowsParentScroll = allowsParentScroll
        view.quarterTurns = (quarterTurns % 4 + 4) % 4
        view.apply(command)
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        private let canvas = UIView()
        let photo = UIImageView()
        var onPrevious: (() -> Void)?
        var onNext: (() -> Void)?
        var onToggleControls: (() -> Void)?
        var onMarkPhoto: ((CGPoint) -> Void)?
        var allowsParentScroll = false
        var quarterTurns = 0

        private var canTurnPage: Bool {
            zoomScale <= minimumZoomScale + 0.01 && !isZooming && !isZoomBouncing
        }
        private var renderedCommand: PhotoZoomCommand?

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false

            canvas.translatesAutoresizingMaskIntoConstraints = false
            photo.translatesAutoresizingMaskIntoConstraints = false
            photo.contentMode = .scaleAspectFit
            photo.isAccessibilityElement = true
            photo.accessibilityLabel = "照片预览"
            photo.accessibilityTraits = .image
            addSubview(canvas)
            canvas.addSubview(photo)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
                canvas.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
                canvas.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
                photo.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                photo.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                photo.topAnchor.constraint(equalTo: canvas.topAnchor),
                photo.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
            ])
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls(_:)))
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(singleTap)

            for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turnPage(_:)))
                swipe.direction = direction
                swipe.delegate = self
                addGestureRecognizer(swipe)
            }
        }

        required init?(coder: NSCoder) { nil }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if allowsParentScroll, gestureRecognizer === panGestureRecognizer, canTurnPage { return false }
            guard super.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
            guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return true }
            return canTurnPage && (swipe.direction == .left ? onNext != nil : onPrevious != nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UISwipeGestureRecognizer && otherGestureRecognizer === panGestureRecognizer
        }

        @objc private func turnPage(_ swipe: UISwipeGestureRecognizer) {
            guard canTurnPage else { return }
            if swipe.direction == .left { onNext?() }
            else { onPrevious?() }
        }

        func apply(_ command: PhotoZoomCommand?) {
            guard let command, renderedCommand != command else { return }
            renderedCommand = command
            if command.reset {
                setZoomScale(minimumZoomScale, animated: true)
            } else {
                let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: canvas)
                zoom(around: center, scale: min(zoomScale * 1.6, maximumZoomScale))
            }
        }

        @objc private func toggleControls(_ gesture: UITapGestureRecognizer) {
            guard let onMarkPhoto else {
                onToggleControls?()
                return
            }
            guard let image = photo.image?.cgImage else { return }
            let size = quarterTurns.isMultiple(of: 2)
                ? CGSize(width: image.width, height: image.height)
                : CGSize(width: image.height, height: image.width)
            let fitted = AVMakeRect(aspectRatio: size, insideRect: photo.bounds)
            let point = gesture.location(in: photo)
            guard fitted.width > 0, fitted.height > 0, fitted.contains(point) else { return }
            let x = (point.x - fitted.minX) / fitted.width
            let y = (point.y - fitted.minY) / fitted.height
            let normalized: CGPoint = switch quarterTurns {
            case 1: CGPoint(x: y, y: 1 - x)
            case 2: CGPoint(x: 1 - x, y: 1 - y)
            case 3: CGPoint(x: 1 - y, y: x)
            default: CGPoint(x: x, y: y)
            }
            onMarkPhoto(normalized)
        }

        @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale + 0.01 {
                setZoomScale(minimumZoomScale, animated: true)
            } else {
                zoom(around: gesture.location(in: canvas), scale: 2.5)
            }
        }

        private func zoom(around point: CGPoint, scale: CGFloat) {
            guard bounds.width > 0 && bounds.height > 0 else { return }
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
            zoom(to: rect, animated: true)
        }
    }
}
