import Accelerate
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws a full-screen carousel slide for one room: a blurred, darkened copy of the album
/// art fills the frame, the cover sits on the right, and the room, title, artist and album
/// are written on the left, like the app's own screen. tvOS's carousel shows only the
/// image, so the text has to be part of it.
///
/// Extensions get a small memory allowance (the system killed an earlier 4K version at
/// 67 MB on an Apple TV 4K), so everything here is drawn at 1080p and kept small.
enum CarouselArtwork {
    /// tvOS scales this up on a 4K screen.
    static let pixelSize = CGSize(width: 1920, height: 1080)

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "TopShelf")
    }

    /// The slide's file, built once per track and room and cached.
    static func image(for room: NowPlaying, session: URLSession) async -> URL? {
        guard let artworkURL = room.artworkURL else { return nil }
        let file = directory.appending(path: fileName(for: room))
        if FileManager.default.fileExists(atPath: file.path()) {
            return file
        }
        // Decode the cover straight to the size it's drawn at, not its full resolution.
        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize.height * 0.62),
        ] as CFDictionary
        guard let (data, _) = try? await session.data(from: artworkURL),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cover = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions),
              let composed = compose(cover, room: room),
              write(composed, to: file)
        else { return nil }
        return file
    }

    /// The slide as a `data:` URL. On a real Apple TV the Home Screen can't read files in
    /// the extension's storage (the simulator can), so the image travels inside the URL.
    static func dataURL(for file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return URL(string: "data:image/jpeg;base64," + data.base64EncodedString())
    }

    /// Deletes cached slides that aren't in use any more.
    static func removeAll(except keep: [URL]) {
        let keepNames = Set(keep.map(\.lastPathComponent))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keepNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Named after everything drawn on the slide, so a new track gets a new file and tvOS
    /// doesn't show a cached one. (Every track on an album shares the same artwork URL.)
    private static func fileName(for room: NowPlaying) -> String {
        let parts = [
            room.artworkURL?.absoluteString, room.sourceLine, room.title, room.artist, room.detail,
            "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
        ]
        let digest = SHA256.hash(data: Data(parts.map { $0 ?? "" }.joined(separator: "\n").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    // MARK: - Drawing

    private static func compose(_ cover: CGImage, room: NowPlaying) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        guard let context = CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Background: a small blurred copy of the cover, stretched to fill and darkened.
        if let background = blurredThumbnail(cover) {
            context.interpolationQuality = .high
            context.draw(background, in: bounds)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.4))
        context.fill(bounds)

        // Darker on the left, behind the text.
        let shade = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(shade, start: .zero, end: CGPoint(x: bounds.width * 0.6, y: 0), options: [])

        // The cover, on the right, with rounded corners and a shadow.
        let side = bounds.height * 0.62
        let frame = CGRect(x: bounds.width * 0.72 - side / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let rounded = CGPath(roundedRect: frame, cornerWidth: side * 0.03, cornerHeight: side * 0.03, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.02), blur: side * 0.08, color: CGColor(gray: 0, alpha: 0.6))
        context.addPath(rounded)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(rounded)
        context.clip()
        context.interpolationQuality = .high
        context.draw(cover, in: frame)
        context.restoreGState()

        // Text, left of the cover and centered on it vertically.
        let left = bounds.width * 0.075
        drawText(room, in: context, x: left, width: frame.minX - bounds.width * 0.05 - left, centerY: frame.midY)

        return context.makeImage()
    }

    /// The same hierarchy as the app's screen: room, title, artist, album. Sizes are in pixels at 1080p.
    private static func drawText(_ room: NowPlaying, in context: CGContext, x: CGFloat, width: CGFloat, centerY: CGFloat) {
        var blocks: [(lines: [CTLine], lineHeight: CGFloat, spaceAfter: CGFloat)] = []
        func add(_ text: String?, size: CGFloat, weight: CTFontUIFontType, alpha: CGFloat, maxLines: Int, spaceAfter: CGFloat) {
            guard let text, !text.isEmpty else { return }
            let font = CTFontCreateUIFontForLanguage(weight, size, nil)!
            let lines = wrappedLines(text, font: font, color: CGColor(gray: 1, alpha: alpha), width: width, maxLines: maxLines)
            blocks.append((lines, size * 1.18, spaceAfter))
        }
        add(room.sourceLine.uppercased(), size: 30, weight: .emphasizedSystem, alpha: 0.6, maxLines: 1, spaceAfter: 20)
        add(room.title, size: 70, weight: .emphasizedSystem, alpha: 1, maxLines: 3, spaceAfter: 12)
        add(room.artist, size: 48, weight: .system, alpha: 0.85, maxLines: 2, spaceAfter: 8)
        add(room.detail, size: 36, weight: .system, alpha: 0.6, maxLines: 2, spaceAfter: 0)

        let height = blocks.reduce(0) { $0 + CGFloat($1.lines.count) * $1.lineHeight + $1.spaceAfter }
        // Core Graphics puts y = 0 at the bottom, so start at the top of the block and work down.
        var baselineTop = centerY + height / 2
        for block in blocks {
            for line in block.lines {
                var ascent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
                context.textPosition = CGPoint(x: x, y: baselineTop - ascent)
                CTLineDraw(line, context)
                baselineTop -= block.lineHeight
            }
            baselineTop -= block.spaceAfter
        }
    }

    /// Breaks text into lines no wider than `width`, ending with "…" if it needs more than `maxLines`.
    private static func wrappedLines(_ text: String, font: CTFont, color: CGColor, width: CGFloat, maxLines: Int) -> [CTLine] {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < maxLines {
            let isLastAllowed = lines.count == maxLines - 1
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if isLastAllowed && start + count < length {
                // Out of lines: put the rest on this one and truncate it.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributed.attributes(at: 0, effectiveRange: nil)))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    /// A 160×90 copy of the cover, cropped to fill and heavily blurred. Stretched to full
    /// screen it looks like a large blur, at a fraction of the memory.
    private static func blurredThumbnail(_ cover: CGImage) -> CGImage? {
        let width = 160, height = 90
        func makeContext() -> CGContext? {
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        guard let small = makeContext(), let scratch = makeContext(),
              let smallData = small.data, let scratchData = scratch.data
        else { return nil }

        let scale = max(CGFloat(width) / CGFloat(cover.width), CGFloat(height) / CGFloat(cover.height))
        let size = CGSize(width: CGFloat(cover.width) * scale, height: CGFloat(cover.height) * scale)
        small.interpolationQuality = .medium
        small.draw(cover, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))

        // Two tent-filter passes, there and back between the two buffers.
        var image = vImage_Buffer(data: smallData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var temporary = vImage_Buffer(data: scratchData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        let flags = vImage_Flags(kvImageEdgeExtend)
        vImageTentConvolve_ARGB8888(&image, &temporary, nil, 0, 0, 31, 31, nil, flags)
        vImageTentConvolve_ARGB8888(&temporary, &image, nil, 0, 0, 31, 31, nil, flags)
        return small.makeImage()
    }

    private static func write(_ image: CGImage, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
