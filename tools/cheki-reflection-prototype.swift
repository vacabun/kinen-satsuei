import CoreImage
import Foundation

// Both inputs must be perspective-corrected to the same four corners and aligned.
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("Usage: swift cheki-reflection-prototype.swift primary.jpg second-angle.jpg result.png")
    exit(64)
}

enum PrototypeError: Error { case unreadableImage, mismatchedAspectRatio }

func loadImage(_ file: String) throws -> CIImage {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: file), options: [.applyOrientationProperty: true]),
          !image.extent.isEmpty else { throw PrototypeError.unreadableImage }
    return image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
}

func highlightRamp(_ image: CIImage, start: CGFloat, width: CGFloat) -> CIImage {
    let scale = 1 / width
    let bias = -start * scale
    return image.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
        "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
    ]).applyingFilter("CIColorClamp")
}

func fuse(primary: CIImage, supplement: CIImage) throws -> CIImage {
    let scaleX = primary.extent.width / supplement.extent.width
    let scaleY = primary.extent.height / supplement.extent.height
    guard abs(scaleX / scaleY - 1) < 0.025 else { throw PrototypeError.mismatchedAspectRatio }
    let secondary = supplement.transformed(by: .init(scaleX: scaleX, y: scaleY)).cropped(to: primary.extent)
    let baseGray = primary.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    let secondGray = secondary.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])

    // A clipped primary pixel is eligible only when the alternate shot is significantly darker.
    let clipped = highlightRamp(baseGray, start: 0.79, width: 0.18)
    let alternateIsDarker = highlightRamp(
        secondGray.applyingFilter("CIColorInvert"), start: 0.13, width: 0.26
    )
    let mask = clipped.applyingFilter("CIMultiplyBlendMode", parameters: [
        kCIInputBackgroundImageKey: alternateIsDarker
    ])
    return secondary.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: primary,
        kCIInputMaskImageKey: mask
    ]).cropped(to: primary.extent)
}

do {
    let primary = try loadImage(arguments[1])
    let supplement = try loadImage(arguments[2])
    let output = URL(fileURLWithPath: arguments[3])
    let staging = output.deletingLastPathComponent().appending(path: ".cheki-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: staging) }
    let result = try fuse(primary: primary, supplement: supplement)
    try CIContext().writePNGRepresentation(of: result, to: staging, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    try FileManager.default.moveItem(at: staging, to: output)
} catch {
    fputs("Could not fuse images: \(error)\n", stderr)
    exit(1)
}
