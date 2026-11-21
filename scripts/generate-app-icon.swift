import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

private func dot(_ context: CGContext, at point: CGPoint, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
}

private func icon(size: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let plate = CGRect(x: 82, y: 89, width: 860, height: 860)
    let tile = CGPath(roundedRect: plate, cornerWidth: 192, cornerHeight: 192, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -20), blur: 36 * scale, color: color(0.02, 0.06, 0.11, 0.5))
    context.setFillColor(color(0.045, 0.11, 0.17))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([
        (0, color(0.14, 0.25, 0.34)),
        (0.42, color(0.075, 0.16, 0.23)),
        (1, color(0.025, 0.064, 0.115))
    ]), start: CGPoint(x: 130, y: 940), end: CGPoint(x: 800, y: 80), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.drawRadialGradient(gradient([
        (0, color(0.05, 0.63, 0.58, 0.22)),
        (1, color(0.04, 0.60, 0.53, 0))
    ]), startCenter: CGPoint(x: 563, y: 565), startRadius: 10,
        endCenter: CGPoint(x: 563, y: 565), endRadius: 420, options: [])

    context.setStrokeColor(color(0.56, 0.83, 0.88, 0.12))
    context.setLineWidth(2)
    for index in 0...6 {
        let x = CGFloat(224 + index * 96)
        let y = CGFloat(231 + index * 96)
        context.move(to: CGPoint(x: x, y: 231))
        context.addLine(to: CGPoint(x: x, y: 807))
        context.move(to: CGPoint(x: 224, y: y))
        context.addLine(to: CGPoint(x: 800, y: y))
    }
    context.strokePath()

    let faintTrace = CGMutablePath()
    faintTrace.move(to: CGPoint(x: 312, y: 617))
    faintTrace.addLine(to: CGPoint(x: 396, y: 617))
    faintTrace.addCurve(to: CGPoint(x: 570, y: 393), control1: CGPoint(x: 500, y: 617), control2: CGPoint(x: 475, y: 393))
    faintTrace.addLine(to: CGPoint(x: 693, y: 393))
    context.setStrokeColor(color(0.34, 0.68, 0.76, 0.55))
    context.setLineWidth(14)
    context.addPath(faintTrace)
    context.strokePath()
    dot(context, at: CGPoint(x: 312, y: 617), radius: 16, fill: color(0.31, 0.67, 0.75))
    dot(context, at: CGPoint(x: 693, y: 393), radius: 16, fill: color(0.31, 0.67, 0.75))

    let start = CGPoint(x: 251, y: 386)
    let end = CGPoint(x: 770, y: 655)
    let trace = CGMutablePath()
    trace.move(to: start)
    trace.addLine(to: CGPoint(x: 365, y: 386))
    trace.addCurve(to: CGPoint(x: 666, y: 655), control1: CGPoint(x: 506, y: 386), control2: CGPoint(x: 525, y: 655))
    trace.addLine(to: end)

    context.saveGState()
    context.setStrokeColor(color(0.26, 0.97, 0.79))
    context.setShadow(offset: .zero, blur: 35 * scale, color: color(0.19, 0.99, 0.77, 0.57))
    context.setLineWidth(27)
    context.addPath(trace)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setLineWidth(26)
    context.addPath(trace)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([
        (0, color(0.15, 0.87, 0.71)),
        (0.56, color(0.39, 1, 0.85)),
        (1, color(0.79, 1, 0.97))
    ]), start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    dot(context, at: start, radius: 29, fill: color(0.24, 0.93, 0.76))
    dot(context, at: start, radius: 12, fill: color(0.78, 1, 0.95))
    dot(context, at: end, radius: 31, fill: color(0.63, 1, 0.91))
    dot(context, at: end, radius: 13, fill: color(0.93, 1, 0.98))
    context.restoreGState()

    let border = CGPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 191, cornerHeight: 191, transform: nil)
    context.setStrokeColor(color(0.56, 0.77, 0.88, 0.40))
    context.setLineWidth(3)
    context.addPath(border)
    context.strokePath()

    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    return image
}

private func writeIcon(size: Int, to output: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, try icon(size: size), nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift generate-app-icon.swift <iconset-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    let stem = "icon_\(size)x\(size)"
    try writeIcon(size: size, to: outputDirectory.appendingPathComponent("\(stem).png"))
    try writeIcon(size: size * 2, to: outputDirectory.appendingPathComponent("\(stem)@2x.png"))
}
