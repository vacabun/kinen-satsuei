import AVFoundation
import CoreImage
import ImageIO
import KinenCore
import SwiftUI

struct ChekiCapturedPhoto: Sendable {
    let original: Data
    let correction: (data: Data, corners: PhotoQuad)?
}

struct ChekiCorrectionFile: Sendable {
    let source: URL
    let corners: PhotoQuad

    init(_ data: Data, corners: PhotoQuad) throws {
        source = URL.temporaryDirectory.appending(path: "KinenCrop-\(UUID().uuidString).jpg")
        self.corners = corners
        try data.write(to: source, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: source) }
}

struct ChekiCropView: View {
    let source: URL
    let existing: PhotoQuad?
    let onApply: (ChekiCorrectionFile?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var corners: [PhotoPoint] = []
    @State private var thumbnail: CGImage?
    @State private var working = false
    @State private var error: String?
    @State private var zoomed = false
    @State private var focusedCorner = 0
    @State private var zoomAnchor: PhotoPoint?

    private static let initialCorners = [
        PhotoPoint(x: 0.12, y: 0.88), PhotoPoint(x: 0.88, y: 0.88),
        PhotoPoint(x: 0.88, y: 0.12), PhotoPoint(x: 0.12, y: 0.12)
    ]
    private let names = ["左上", "右上", "右下", "左下"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let thumbnail, corners.count == 4 {
                    GeometryReader { proxy in
                        let canvas = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 18, dy: 18)
                        let fit = AVMakeRect(aspectRatio: CGSize(width: thumbnail.width, height: thumbnail.height),
                                             insideRect: canvas)
                        let rect = zoomAnchor.map { anchor in
                            CGRect(x: fit.midX - anchor.x * fit.width * 2,
                                   y: fit.midY - (1 - anchor.y) * fit.height * 2,
                                   width: fit.width * 2, height: fit.height * 2)
                        } ?? fit
                        ZStack(alignment: .topLeading) {
                            Image(decorative: thumbnail, scale: 1).resizable()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                            Path { path in
                                path.addLines(corners.map { point($0, in: rect) })
                                path.closeSubpath()
                            }
                            .stroke(.black.opacity(0.8), lineWidth: 7)
                            Path { path in
                                path.addLines(corners.map { point($0, in: rect) })
                                path.closeSubpath()
                            }
                            .stroke(.white, lineWidth: 3)
                            ForEach(corners.indices, id: \.self) { index in
                                handle(index, in: rect)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .clipped()
                        .coordinateSpace(name: "cheki-crop")
                    }
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    HStack(spacing: 10) {
                        Picker("放大的角", selection: $focusedCorner) {
                            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
                        }
                        Button(zoomed ? "缩回全图" : "放大角点", systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass") {
                            zoomed.toggle()
                            zoomAnchor = zoomed ? corners[focusedCorner] : nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(working)
                    .onChange(of: focusedCorner) { _, index in
                        if zoomed { zoomAnchor = corners[index] }
                    }
                } else if error == nil {
                    ProgressView("正在读取原图").frame(maxHeight: .infinity)
                }
                if let error {
                    Text(error).font(.footnote)
                } else {
                    Text("拖动四个圆点，对齐拍立得相纸的外缘。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("使用原图") {
                    onApply(nil)
                    dismiss()
                }
                .disabled(working)
            }
            .padding()
            .background(Color.kinenCanvas.ignoresSafeArea())
            .navigationTitle("四角校正")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                        .disabled(working || thumbnail == nil)
                }
            }
            .task {
                corners = existing?.corners ?? Self.initialCorners
                thumbnail = await Task.detached(priority: .userInitiated) {
                    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(image, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1400
                    ] as CFDictionary)
                }.value
                if thumbnail == nil { error = "无法读取原图。" }
            }
        }
    }

    private func point(_ corner: PhotoPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * corner.x, y: rect.maxY - rect.height * corner.y)
    }

    private func handle(_ index: Int, in rect: CGRect) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: 20, height: 20)
            Circle().strokeBorder(.black, lineWidth: 2).frame(width: 20, height: 20)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(point(corners[index], in: rect))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cheki-crop"))
            .onChanged { value in
                guard rect.width > 0, rect.height > 0 else { return }
                let x = min(1, max(0, (value.location.x - rect.minX) / rect.width))
                let y = min(1, max(0, (rect.maxY - value.location.y) / rect.height))
                corners[index] = PhotoPoint(x: x, y: y)
                error = nil
            })
        .accessibilityLabel(names[index] + "角")
        .accessibilityValue("\(Int(corners[index].x * 100))％，\(Int(corners[index].y * 100))％")
        .accessibilityAction(named: Text("向左微调")) { nudge(index, x: -0.005, y: 0) }
        .accessibilityAction(named: Text("向右微调")) { nudge(index, x: 0.005, y: 0) }
        .accessibilityAction(named: Text("向上微调")) { nudge(index, x: 0, y: 0.005) }
        .accessibilityAction(named: Text("向下微调")) { nudge(index, x: 0, y: -0.005) }
    }

    private func nudge(_ index: Int, x: Double, y: Double) {
        let point = corners[index]
        corners[index] = PhotoPoint(x: min(1, max(0, point.x + x)), y: min(1, max(0, point.y + y)))
        error = nil
    }

    private func apply() {
        guard let quad = PhotoQuad(corners: corners) else {
            error = "四角不能交叉，且需要围出一块有效区域。"
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    guard let original = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]),
                          let bytes = ChekiImageCorrection.jpeg(image: original, corners: quad, context: CIContext()) else {
                        throw LibraryError.invalidAsset
                    }
                    return try ChekiCorrectionFile(bytes, corners: quad)
                }.value
                onApply(image)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension ChekiAdjustments {
    func preview(at url: URL, pixels: Int, showsGlareMask: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        let sourceImage = CIImage(cgImage: thumbnail)
        let image = showsGlareMask ? glareMaskPreview(sourceImage) : adjusted(sourceImage)
        return Self.context.createCGImage(image, from: image.extent)
    }

    func export(at source: URL) async throws -> URL? {
        guard !isNeutral else { return nil }
        return try await LibraryWork.run {
            Result {
                guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]),
                      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let target = URL.temporaryDirectory.appending(path: "KinenAdjust-\(UUID().uuidString).jpg")
                do {
                    try Task.checkCancellation()
                    try Self.context.writeJPEGRepresentation(of: adjusted(image), to: target,
                                                             colorSpace: colorSpace)
                    try Task.checkCancellation()
                    return target
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    throw error
                }
            }
        }.get()
    }

    private static var context: CIContext { ChekiAdjustmentContext.shared }

    private func adjusted(_ source: CIImage) -> CIImage {
        var image = source
        if glare > 0 {
            let reduced = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 - 0.08 * glare),
                "inputPoint4": CIVector(x: 1, y: 1 - 0.18 * glare)
            ])
            image = glareExclusions == nil ? reduced : blend(reduced, over: image, mask: glareMask(image))
        }
        if exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        if contrast != 0 || saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + contrast,
                kCIInputSaturationKey: 1 + saturation
            ])
        }
        return image
    }

    private func glareMaskPreview(_ source: CIImage) -> CIImage {
        let tint = CIImage(color: CIColor(red: 1, green: 0.16, blue: 0.24, alpha: 0.72)).cropped(to: source.extent)
        return blend(tint.composited(over: source), over: source, mask: glareMask(source))
    }

    private func glareMask(_ source: CIImage) -> CIImage {
        let extent = source.extent
        let shortSide = min(extent.width, extent.height)
        let gray = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let neighborhood = gray.clampedToExtent()
            .applyingGaussianBlur(sigma: shortSide * 0.035).cropped(to: extent)
        let localDifference = gray.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: neighborhood
        ])
        let highlights = ramp(gray, start: 0.55, width: 0.32)
        let localContrast = ramp(localDifference, start: 0.035, width: 0.17)
        var mask = multiply(highlights, by: localContrast)
            .clampedToExtent().applyingGaussianBlur(sigma: shortSide * 0.004).cropped(to: extent)
        mask = multiply(mask, by: highlights)
        for region in glareRegions(glareInclusions, extent: extent, shortSide: shortSide, including: true) {
            mask = mask.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: multiply(region, by: highlights)
            ])
        }
        for region in glareRegions(glareExclusions, extent: extent, shortSide: shortSide, including: false) {
            mask = multiply(mask, by: region)
        }
        return mask
    }

    private func glareRegions(_ points: [GlarePoint]?, extent: CGRect, shortSide: CGFloat, including: Bool) -> [CIImage] {
        (points ?? []).prefix(16).compactMap { point in
            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
            let radius = shortSide * ((0.025...0.2).contains(point.radius ?? 0) ? point.radius ?? 0.09 : 0.09)
            let center = CIVector(x: extent.minX + point.x * extent.width, y: extent.maxY - point.y * extent.height)
            return CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: center,
                "inputRadius0": radius * 0.7, "inputRadius1": radius,
                "inputColor0": including ? CIColor.white : CIColor.black,
                "inputColor1": including ? CIColor.black : CIColor.white
            ])?.outputImage?.cropped(to: extent)
        }
    }

    private func ramp(_ image: CIImage, start: CGFloat, width: CGFloat) -> CIImage {
        let scale = 1 / width
        let bias = -start * scale
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ]).applyingFilter("CIColorClamp")
    }

    private func multiply(_ image: CIImage, by mask: CIImage) -> CIImage {
        image.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: mask])
    }

    private func blend(_ image: CIImage, over source: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask
        ])
    }

}

private enum ChekiAdjustmentContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}

struct ChekiAdjustmentEditor: View {
    let source: URL
    let quarterTurns: Int
    let onApply: (ChekiAdjustments) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: ChekiAdjustments
    @State private var previewMode = PreviewMode.result

    private enum PreviewMode: String, CaseIterable {
        case original = "调整前"
        case result = "调整后"
        case mask = "反光遮罩"
    }
    @State private var addingGlare = false
    @State private var markSize = MarkSize.medium

    private enum MarkSize: String, CaseIterable {
        case small = "小"
        case medium = "中"
        case large = "大"

        var radius: Double {
            switch self {
            case .small: 0.035
            case .medium: 0.09
            case .large: 0.16
            }
        }
    }

    init(source: URL, quarterTurns: Int, values: ChekiAdjustments,
         onApply: @escaping (ChekiAdjustments) -> Void) {
        self.source = source
        self.quarterTurns = quarterTurns
        self.onApply = onApply
        _values = State(initialValue: values)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ChekiAdjustedPreview(source: source, values: previewMode == .original ? .init() : values,
                                         quarterTurns: quarterTurns, showsGlareMask: previewMode == .mask, zoomable: true,
                                         onMark: previewMode == .mask ? markGlare : nil)
                        .frame(height: 245)
                        .frame(maxWidth: .infinity)
                        .kinenCard()
                    Picker("预览方式", selection: $previewMode) {
                        ForEach(PreviewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        if previewMode == .mask {
                            Button("撤销标记", systemImage: "arrow.uturn.backward") {
                                if addingGlare { _ = values.glareInclusions?.popLast() }
                                else { _ = values.glareExclusions?.popLast() }
                            }
                            .disabled(markCount == 0)
                        }
                        Spacer()
                        Button("重置") {
                            values = .init()
                            previewMode = .result
                        }
                        .disabled(values.isNeutral && values.glareExclusions?.isEmpty != false && values.glareInclusions?.isEmpty != false)
                    }
                    .font(.subheadline)
                    control("减弱反光", value: $values.glare, range: 0...1, factor: 100)
                        .onChange(of: values.glare) { _, strength in
                            if strength > 0, values.glareExclusions == nil { values.glareExclusions = [] }
                        }
                    if previewMode == .mask {
                        if values.glare == 0 {
                            Text("遮罩可先查看和标记。调高减弱反光强度后，处理才会生效。")
                                .font(.footnote).foregroundStyle(Color.kinenMuted)
                        }
                        Picker("标记方式", selection: $addingGlare) {
                            Text("排除误选").tag(false)
                            Text("补选亮斑").tag(true)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("标记大小").font(.subheadline)
                            Picker("标记大小", selection: $markSize) {
                                ForEach(MarkSize.allCases, id: \.self) { size in
                                    Text(size.rawValue).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        Text(markCount >= 16
                             ? "当前方式已标记 16 处。撤销后可继续标记。"
                             : addingGlare ? "点选漏检的亮斑，补入红色处理区域。"
                             : "点选被标红的白边、衣服或签名，将该处排除。")
                            .font(.footnote).foregroundStyle(Color.kinenMuted)
                    }
                    control("曝光", value: $values.exposure, range: -1...1, factor: 100)
                    control("对比度", value: $values.contrast, range: -0.35...0.35, factor: 100)
                    control("饱和度", value: $values.saturation, range: -0.5...0.5, factor: 100)
                    Text("减弱反光可压低亮斑。已经拍成纯白的区域无法恢复细节。")
                        .font(.footnote).foregroundStyle(Color.kinenMuted)
                }
                .padding(20)
            }
            .background(Color.kinenCanvas)
            .navigationTitle("图像调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(values)
                        dismiss()
                    }
                }
            }
        }
    }

    private var markCount: Int {
        (addingGlare ? values.glareInclusions : values.glareExclusions)?.count ?? 0
    }

    private func markGlare(_ point: CGPoint) {
        guard markCount < 16 else { return }
        if values.glareExclusions == nil { values.glareExclusions = [] }
        let mark = ChekiAdjustments.GlarePoint(x: point.x, y: point.y, radius: markSize.radius)
        if addingGlare {
            values.glareInclusions = (values.glareInclusions ?? []) + [mark]
        } else {
            values.glareExclusions?.append(mark)
        }
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, factor: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: String(Int((value.wrappedValue * factor).rounded())))
                .font(.subheadline.monospacedDigit())
                .accessibilityHidden(true)
            Slider(value: value, in: range, step: 0.01) { Text(title) }
                .accessibilityValue(String(Int((value.wrappedValue * factor).rounded())))
                .onChange(of: value.wrappedValue) { _, _ in
                    if previewMode == .original { previewMode = .result }
                }
        }
    }
}

struct ChekiAdjustedPreview: View {
    let source: URL
    let values: ChekiAdjustments
    let quarterTurns: Int
    var showsGlareMask = false
    var zoomable = false
    var onMark: ((CGPoint) -> Void)? = nil
    @State private var image: CGImage?

    private struct Request: Equatable {
        let source: URL
        let values: ChekiAdjustments
        let showsGlareMask: Bool
    }

    var body: some View {
        let request = Request(source: source, values: values, showsGlareMask: showsGlareMask)
        let turns = (quarterTurns % 4 + 4) % 4
        let pixels = zoomable ? 1440 : 900
        Group {
            if zoomable {
                ZoomableInspectionImage(image: image, quarterTurns: quarterTurns, command: nil,
                                        previous: nil, next: nil, toggleControls: {}, markPhoto: onMark,
                                        allowsParentScroll: true)
            } else if let image {
                GeometryReader { geometry in
                    let available = turns.isMultiple(of: 2) ? geometry.size
                        : CGSize(width: geometry.size.height, height: geometry.size.width)
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(width: available.width, height: available.height)
                        .rotationEffect(.degrees(Double(turns) * 90))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                AssetImage(url: source, maxPixels: 900, icon: "photo", quarterTurns: quarterTurns)
            }
        }
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(55)) }
            catch { return }
            let rendered = await LibraryWork.run {
                request.values.preview(at: request.source, pixels: pixels, showsGlareMask: request.showsGlareMask)
            }
            if !Task.isCancelled { image = rendered }
        }
    }
}
