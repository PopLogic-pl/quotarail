import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ rgb: UInt32) -> CGColor {
    CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, from top: UInt32, to bottom: UInt32,
          in rect: CGRect) {
    let colors = [color(top), color(bottom)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors, locations: [0, 1])!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    context.restoreGState()
}

func render(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    let tile = CGRect(x: 79, y: 79, width: 866, height: 866)
    let face = rounded(tile, radius: 194)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 26,
                      color: CGColor(gray: 0, alpha: 0.42))
    context.setFillColor(color(0x131a20))
    context.addPath(face)
    context.fillPath()
    context.restoreGState()
    fill(context, face, from: 0x313a41, to: 0x11181f, in: tile)

    let bevel = tile.insetBy(dx: 6, dy: 6)
    context.addPath(rounded(bevel, radius: 188))
    context.setStrokeColor(color(0x49555d))
    context.setLineWidth(10)
    context.strokePath()

    let rail = CGRect(x: 225, y: 456, width: 574, height: 112)
    fill(context, rounded(rail, radius: 30), from: 0x101619, to: 0x343f45, in: rail)

    for row in 0..<2 {
        for column in 0..<3 {
            let module = CGRect(x: 302 + column * 147, y: 371 + row * 148,
                                width: 126, height: 126)
            let base = module.offsetBy(dx: 0, dy: -9)
            fill(context, rounded(base, radius: 27), from: 0x33464c, to: 0x0e171a, in: base)
            let mint = (row + column).isMultiple(of: 2)
            fill(context, rounded(module, radius: 27),
                 from: mint ? 0xbdf4dc : 0xc5d1da, to: mint ? 0x55ba9d : 0x758991, in: module)
            let inset = module.insetBy(dx: 10, dy: 10)
            context.addPath(rounded(inset, radius: 20))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.26))
            context.setLineWidth(4)
            context.strokePath()
        }
    }

    for direction in [-1, 1] {
        let edge: CGFloat = direction < 0 ? 232 : 792
        let tip = edge - 48 * CGFloat(direction)
        let bracket = CGMutablePath()
        bracket.move(to: CGPoint(x: tip, y: 681))
        bracket.addLine(to: CGPoint(x: edge, y: 681))
        bracket.addLine(to: CGPoint(x: edge, y: 343))
        bracket.addLine(to: CGPoint(x: tip, y: 343))
        let silhouette = bracket.copy(strokingWithWidth: 41, lineCap: .round,
                                      lineJoin: .round, miterLimit: 0)
        fill(context, silhouette, from: 0xff8473, to: 0xef4c3c, in: silhouette.boundingBox)
    }

    return context.makeImage()!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        let url = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, render(size: size * density), nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
}
