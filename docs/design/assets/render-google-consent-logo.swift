#!/usr/bin/env swift

import AppKit
import Foundation

private let fileURL = URL(fileURLWithPath: #filePath)
private let assetDirectory = fileURL.deletingLastPathComponent()
private let repositoryRoot = assetDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let sourceURL = repositoryRoot
    .appendingPathComponent("Distribution/assets/png/icon_1024.png")

private let logoSize = 120
private let forest = NSColor(srgbRed: 10 / 255, green: 61 / 255, blue: 45 / 255, alpha: 1)
private let googleDarkSurface = NSColor(srgbRed: 32 / 255, green: 33 / 255, blue: 36 / 255, alpha: 1)

private let sourceImage: NSImage = {
    guard let image = NSImage(contentsOf: sourceURL) else {
        fatalError("Could not load app-icon source at \(sourceURL.path)")
    }
    return image
}()

private func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let cgContext = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("Could not allocate \(width)x\(height) bitmap")
    }

    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = cgContext.makeImage() else {
        fatalError("Could not create \(width)x\(height) image")
    }
    return NSBitmapImageRep(cgImage: image)
}

private func writePNG(_ representation: NSBitmapImageRep, named name: String) {
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(name)")
    }
    do {
        try data.write(to: assetDirectory.appendingPathComponent(name), options: .atomic)
    } catch {
        fatalError("Could not write \(name): \(error)")
    }
}

private let logo = bitmap(width: logoSize, height: logoSize) { canvas in
    forest.setFill()
    canvas.fill()
    sourceImage.draw(
        in: canvas,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}
writePNG(logo, named: "google-consent-logo-120.png")

private func preview(name: String, scale: Int, surface: NSColor) {
    let width = 320 * scale
    let height = 200 * scale
    let renderedLogoSize = logoSize * scale
    let previewImage = NSImage(size: NSSize(width: logoSize, height: logoSize))
    previewImage.addRepresentation(logo)

    let representation = bitmap(width: width, height: height) { canvas in
        surface.setFill()
        canvas.fill()
        let logoRect = NSRect(
            x: (width - renderedLogoSize) / 2,
            y: (height - renderedLogoSize) / 2,
            width: renderedLogoSize,
            height: renderedLogoSize
        )
        previewImage.draw(
            in: logoRect,
            from: NSRect(x: 0, y: 0, width: logoSize, height: logoSize),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }
    writePNG(representation, named: name)
}

preview(name: "google-consent-logo-preview-white-1x.png", scale: 1, surface: .white)
preview(name: "google-consent-logo-preview-white-2x.png", scale: 2, surface: .white)
preview(name: "google-consent-logo-preview-dark-1x.png", scale: 1, surface: googleDarkSurface)
preview(name: "google-consent-logo-preview-dark-2x.png", scale: 2, surface: googleDarkSurface)

print("Rendered Google consent logo and 1x/2x previews from \(sourceURL.path)")
