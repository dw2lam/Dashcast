import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pixel-exact QR code: each module is a whole number of backing pixels, drawn nearest-neighbour.
struct QRCodeView: View {
    let string: String
    /// Target side length in points; snapped down to a whole number of pixels per module.
    var size: CGFloat = 96

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = QRCodeCache.image(for: string) {
            let modules = CGFloat(image.width)
            let pixelsPerModule = max(1, floor(size * displayScale / modules))
            let side = modules * pixelsPerModule / displayScale
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: side, height: side)
                .padding(6)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.black.opacity(0.08))
                }
                .accessibilityLabel("QR code for \(string)")
        }
    }
}

@MainActor
private enum QRCodeCache {
    private static var images: [String: CGImage] = [:]

    static func image(for string: String) -> CGImage? {
        if let cached = images[string] { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
        else { return nil }
        images[string] = image
        return image
    }
}
