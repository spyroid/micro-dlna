import AppKit

/// Small PNG thumbnails for UPnP clients, rendered from native macOS symbols.
enum MediaIcon: String, CaseIterable {
    case folder = "folder-dark-gray"
    case mp3, m4a, flac, wav, mp4, m4v, mkv, mov, avi, jpg, jpeg, png

    var path: String { "/icons/\(rawValue).png" }

    private var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .mp4, .m4v, .mkv, .mov, .avi: return "film.fill"
        case .mp3, .m4a, .flac, .wav: return "music.note"
        case .jpg, .jpeg, .png: return "photo.fill"
        }
    }

    private var color: NSColor {
        // Fixed, distinct backgrounds keep file formats recognizable in any macOS appearance.
        let rgb: (red: CGFloat, green: CGFloat, blue: CGFloat)
        switch self {
        case .folder: rgb = (0.28, 0.28, 0.28)  // Dark neutral gray
        case .mp3: rgb = (0.78, 0.35, 0.00)  // Orange
        case .m4a: rgb = (0.80, 0.21, 0.29)  // Red
        case .flac: rgb = (0.71, 0.17, 0.47)  // Pink
        case .wav: rgb = (0.57, 0.44, 0.00)  // Gold
        case .mp4: rgb = (0.48, 0.22, 0.74)  // Purple
        case .m4v: rgb = (0.27, 0.29, 0.70)  // Indigo
        case .mkv: rgb = (0.00, 0.49, 0.53)  // Teal
        case .mov: rgb = (0.00, 0.45, 0.67)  // Cyan
        case .avi: rgb = (0.33, 0.40, 0.48)  // Slate
        case .jpg: rgb = (0.16, 0.51, 0.24)  // Green
        case .jpeg: rgb = (0.39, 0.48, 0.11)  // Olive
        case .png: rgb = (0.59, 0.36, 0.20)  // Brown
        }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    // Generate each image once; every file of the same kind shares its thumbnail URL.
    static let images: [String: Data] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { icon in
            icon.renderPNG().map { (icon.path, $0) }
        })

    private func renderPNG() -> Data? {
        let size = 160
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap),
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white]))
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        context.cgContext.clear(bounds)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 28, yRadius: 28).fill()

        // Preserve symbol proportions while centering it on the colored background.
        let scale = min(96 / image.size.width, 96 / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let imageRect = NSRect(
            x: (160 - width) / 2, y: (160 - height) / 2, width: width, height: height)
        image.draw(in: imageRect)
        return bitmap.representation(using: .png, properties: [:])
    }
}
