import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum ChekiImageCorrection {
    public static func jpeg(image: CIImage, corners: PhotoQuad, context: CIContext) -> Data? {
        let filter = CIFilter.perspectiveCorrection()
        let extent = image.extent
        let points = corners.corners.map {
            CGPoint(x: extent.minX + CGFloat($0.x) * extent.width, y: extent.minY + CGFloat($0.y) * extent.height)
        }
        filter.inputImage = image
        filter.topLeft = points[0]
        filter.topRight = points[1]
        filter.bottomRight = points[2]
        filter.bottomLeft = points[3]
        guard let corrected = filter.outputImage, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: corrected, colorSpace: colorSpace)
    }
}
