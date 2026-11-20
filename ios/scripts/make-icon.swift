#!/usr/bin/env swift
// Draws the app icon: 1024 x 1024, the brand's lower-case "n" in the app's rounded bold face,
// white on green. Opaque RGB, as App Store Connect requires. Needs a Mac (the system's rounded
// font); the PNG it writes is committed, so a build does not run this.
//
//     swift ios/scripts/make-icon.swift            # writes App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//     swift ios/scripts/make-icon.swift out.png    # writes somewhere else, to look at a change first
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let letter = "n"
/// The letter's height as a share of the icon. A lower-case n is about as wide as it is tall, so
/// this leaves roughly a quarter of the icon free on every side.
let letterHeightShare: CGFloat = 0.46
let top = CGColor(srgbRed: 0x3D / 255, green: 0x97 / 255, blue: 0x70 / 255, alpha: 1)
let bottom = CGColor(srgbRed: 0x25 / 255, green: 0x6C / 255, blue: 0x4E / 255, alpha: 1)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast: no alpha channel in the bitmap, so none in the PNG.
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no bitmap context") }

let side = CGFloat(size)
let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])

// The rounded design of the system font, bold: the face the app writes its name in.
let base = NSFont.systemFont(ofSize: 1000, weight: .bold)
guard let rounded = base.fontDescriptor.withDesign(.rounded),
      let font = NSFont(descriptor: rounded, size: 1000) else { fatalError("no rounded system font") }
let ctFont = font as CTFont
var character = Array(letter.utf16)
var glyph = CGGlyph(0)
guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1),
      let outline = CTFontCreatePathForGlyph(ctFont, glyph, nil) else { fatalError("no glyph") }

// Centred by the letter's own outline, not by the font's line box, which sits a lower-case letter
// too low.
let box = outline.boundingBoxOfPath
let scale = side * letterHeightShare / box.height
var place = CGAffineTransform(translationX: (side - box.width * scale) / 2 - box.minX * scale,
                              y: (side - box.height * scale) / 2 - box.minY * scale)
    .scaledBy(x: scale, y: scale)
guard let placed = outline.copy(using: &place) else { fatalError("no path") }
context.addPath(placed)
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.fillPath()

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : here.appendingPathComponent("../App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").standardizedFileURL
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(out.path)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(out.path)") }
print(out.path)
