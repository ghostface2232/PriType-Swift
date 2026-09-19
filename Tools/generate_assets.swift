import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func bitmap(width: Int, height: Int, pointSize: CGFloat? = nil, draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create bitmap")
    }

    let logicalSize = pointSize ?? CGFloat(width)
    rep.size = NSSize(width: logicalSize, height: logicalSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = true
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(width))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writeTIFF(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .tiff, properties: [:]) else {
        fatalError("Failed to encode TIFF")
    }
    try data.write(to: url)
}

func centeredTextOrigin(text: String, attributes: [NSAttributedString.Key: Any], canvasSize: CGFloat) -> NSPoint {
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: 0, length: attributed.length),
        nil,
        CGSize(width: canvasSize * 2, height: canvasSize * 2),
        nil
    )
    return NSPoint(
        x: (canvasSize - suggested.width) * 0.5,
        y: (canvasSize - suggested.height) * 0.5
    )
}

struct GlyphFont {
    let name: String?
    let size: CGFloat
}

func drawInputGlyphRep(
    _ glyph: String,
    font glyphFont: GlyphFont,
    canvasSize: CGFloat,
    pixels: Int,
    offset: CGPoint
) -> NSBitmapImageRep {
    bitmap(width: pixels, height: pixels, pointSize: canvasSize) { _ in
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = glyphFont.name.flatMap { NSFont(name: $0, size: glyphFont.size) }
            ?? NSFont.systemFont(ofSize: glyphFont.size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.02, alpha: 0.92),
            .paragraphStyle: paragraph,
            .kern: 0
        ]
        let origin = centeredTextOrigin(text: glyph, attributes: attrs, canvasSize: canvasSize)
        NSString(
            string: glyph
        ).draw(
            at: NSPoint(x: origin.x + offset.x, y: origin.y + offset.y),
            withAttributes: attrs
        )
    }
}

func drawGlyphPDF(
    _ glyph: String,
    fontName: String?,
    fontSize: CGFloat,
    canvasSize: CGFloat,
    xOffset: CGFloat = 0,
    yOffset: CGFloat = 0,
    to url: URL
) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        fatalError("Failed to create PDF consumer")
    }

    var mediaBox = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        fatalError("Failed to create PDF context")
    }

    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = fontName.flatMap { NSFont(name: $0, size: fontSize) }
        ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.0, alpha: 1.0),
        .paragraphStyle: paragraph,
        .kern: 0
    ]
    let origin = centeredTextOrigin(text: glyph, attributes: attrs, canvasSize: canvasSize)
    NSString(string: glyph).draw(
        at: NSPoint(x: origin.x + xOffset, y: origin.y + yOffset),
        withAttributes: attrs
    )

    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: url)
}

func drawInputGlyph(_ glyph: String, fontName: String?, fontSize: CGFloat, xOffset: CGFloat = 0, yOffset: CGFloat = 0) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    let font = GlyphFont(name: fontName, size: fontSize)
    let offset = CGPoint(x: xOffset, y: yOffset)
    image.addRepresentation(drawInputGlyphRep(glyph, font: font, canvasSize: 16, pixels: 16, offset: offset))
    image.addRepresentation(drawInputGlyphRep(glyph, font: font, canvasSize: 16, pixels: 32, offset: offset))
    return image
}

func writeTIFF(_ image: NSImage, to url: URL) throws {
    guard let data = image.tiffRepresentation else {
        fatalError("Failed to encode multi-representation TIFF")
    }
    try data.write(to: url)
}

try writeTIFF(
    drawInputGlyph("한", fontName: "AppleSDGothicNeo-Bold", fontSize: 15.0, yOffset: -1.15),
    to: root.appendingPathComponent("input-ko.tiff")
)
try writeTIFF(
    drawInputGlyph("A", fontName: nil, fontSize: 16.0, yOffset: -0.20),
    to: root.appendingPathComponent("input-en.tiff")
)
try writeTIFF(
    drawInputGlyph("한", fontName: "AppleSDGothicNeo-Bold", fontSize: 15.0, yOffset: -1.15),
    to: root.appendingPathComponent("icon.tiff")
)
print("Generated input source TIFF assets.")
