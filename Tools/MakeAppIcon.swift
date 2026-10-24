// Renders the tvOS app icon and Top Shelf images for Sonos TV.
//
// Usage, from the project root:
//   swift Tools/MakeAppIcon.swift SonosTV/Assets.xcassets
//
// The icon is two layers so tvOS can give it parallax when focused: a gradient
// background, and an album sleeve with a record sliding out of it in front.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let catalog = CommandLine.arguments.dropFirst().first ?? "SonosTV/Assets.xcassets"
let brand = "\(catalog)/App Icon & Top Shelf Image.brandassets"

// MARK: - Drawing

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let ember = color(0xFF7A45)
let berry = color(0xC2306B)
let plum = color(0x3A1360)
let sleeveWhite = color(0xF7F2EC)
let vinyl = color(0x141014)

/// Sunset gradient, top left to bottom right, with a soft highlight.
func drawBackground(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [ember, berry, plum] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

    let glow = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    let center = CGPoint(x: w * 0.25, y: h * 0.8)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: max(w, h) * 0.6, options: [])
}

/// An album sleeve with "now playing" bars, and a record sliding out to the right.
/// `size` is the sleeve's side length; the whole drawing is about 1.4 × size wide.
func drawArtwork(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, size s: CGFloat) {
    let sleeveCenter = CGPoint(x: w / 2 - 0.22 * s, y: h / 2)
    let discCenter = CGPoint(x: sleeveCenter.x + 0.46 * s, y: h / 2)
    let discRadius = 0.46 * s

    func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    // Record, with grooves, a label and a spindle hole.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.02 * s), blur: 0.08 * s, color: color(0x000000, alpha: 0.35))
    ctx.setFillColor(vinyl)
    ctx.fillEllipse(in: circle(discCenter, discRadius))
    ctx.restoreGState()

    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.09))
    ctx.setLineWidth(max(1, 0.004 * s))
    for radius in stride(from: 0.19 * s, through: 0.43 * s, by: 0.035 * s) {
        ctx.strokeEllipse(in: circle(discCenter, radius))
    }
    ctx.setFillColor(ember)
    ctx.fillEllipse(in: circle(discCenter, 0.15 * s))
    ctx.setFillColor(vinyl)
    ctx.fillEllipse(in: circle(discCenter, 0.022 * s))

    // Sleeve.
    let sleeve = CGRect(x: sleeveCenter.x - s / 2, y: sleeveCenter.y - s / 2, width: s, height: s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.03 * s), blur: 0.1 * s, color: color(0x000000, alpha: 0.4))
    ctx.setFillColor(sleeveWhite)
    ctx.addPath(CGPath(roundedRect: sleeve, cornerWidth: 0.07 * s, cornerHeight: 0.07 * s, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Three "now playing" bars on the sleeve.
    let barWidth = 0.11 * s
    let gap = 0.075 * s
    let heights: [CGFloat] = [0.40, 0.60, 0.28].map { $0 * s }
    let bottom = sleeveCenter.y - 0.28 * s
    var x = sleeveCenter.x - (3 * barWidth + 2 * gap) / 2
    ctx.setFillColor(berry)
    for height in heights {
        let bar = CGRect(x: x, y: bottom, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }
}

// MARK: - Output

func render(_ width: Int, _ height: Int, opaque: Bool, to path: String, draw: (CGContext, CGFloat, CGFloat) -> Void) {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue
    )!
    draw(ctx, CGFloat(width), CGFloat(height))
    let url = URL(fileURLWithPath: path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "Couldn't write \(path)")
}

func writeJSON(_ json: String, to directory: String) {
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try! json.write(toFile: "\(directory)/Contents.json", atomically: true, encoding: .utf8)
}

let info = #""info" : { "author" : "xcode", "version" : 1 }"#

func imageSetJSON(_ name: String, scales: [Int]) -> String {
    let images = scales.map { scale in
        let file = scale == 1 ? "\(name).png" : "\(name)@\(scale)x.png"
        return #"{ "filename" : "\#(file)", "idiom" : "tv", "scale" : "\#(scale)x" }"#
    }
    return "{\n  \"images\" : [\n    \(images.joined(separator: ",\n    "))\n  ],\n  \(info)\n}\n"
}

/// A layered icon: an opaque back layer and a transparent front layer.
func writeImageStack(_ name: String, width: Int, height: Int, scales: [Int]) {
    let stack = "\(brand)/\(name).imagestack"
    writeJSON(#"{ "layers" : [ { "filename" : "Front.imagestacklayer" }, { "filename" : "Back.imagestacklayer" } ], \#(info) }"#, to: stack)
    for (layer, file) in [("Back", "back"), ("Front", "front")] {
        writeJSON("{ \(info) }", to: "\(stack)/\(layer).imagestacklayer")
        let imageSet = "\(stack)/\(layer).imagestacklayer/Content.imageset"
        writeJSON(imageSetJSON(file, scales: scales), to: imageSet)
        for scale in scales {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            render(width * scale, height * scale, opaque: layer == "Back", to: "\(imageSet)/\(file)\(suffix).png") { ctx, w, h in
                if layer == "Back" {
                    drawBackground(ctx, w, h)
                } else {
                    drawArtwork(ctx, w, h, size: h * 0.56)
                }
            }
        }
    }
}

/// A flat banner for the Home Screen's Top Shelf.
func writeTopShelf(_ name: String, file: String, width: Int, height: Int) {
    let imageSet = "\(brand)/\(name).imageset"
    writeJSON(imageSetJSON(file, scales: [1, 2]), to: imageSet)
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        render(width * scale, height * scale, opaque: true, to: "\(imageSet)/\(file)\(suffix).png") { ctx, w, h in
            drawBackground(ctx, w, h)
            drawArtwork(ctx, w, h, size: h * 0.56)
        }
    }
}

writeJSON("{ \(info) }", to: catalog)
writeJSON("""
{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
  ],
  \(info)
}

""", to: brand)
writeImageStack("App Icon", width: 400, height: 240, scales: [1, 2])
writeImageStack("App Icon - App Store", width: 1280, height: 768, scales: [1])
writeTopShelf("Top Shelf Image", file: "top-shelf", width: 1920, height: 720)
writeTopShelf("Top Shelf Image Wide", file: "top-shelf-wide", width: 2320, height: 720)
print("Wrote \(brand)")
