import AppKit
import CoreGraphics
import Foundation

enum IconError: Error {
    case missingArgument
    case imageLoadFailed(String)
    case bitmapContextFailed
    case imageWriteFailed(String)
}

enum IconLayout {
    case paddedEmblem
    case fillSquareRounded
}

let iconRenditions = [
    (filename: "icon_16x16.png", size: 16),
    (filename: "icon_16x16@2x.png", size: 32),
    (filename: "icon_32x32.png", size: 32),
    (filename: "icon_32x32@2x.png", size: 64),
    (filename: "icon_128x128.png", size: 128),
    (filename: "icon_128x128@2x.png", size: 256),
    (filename: "icon_256x256.png", size: 256),
    (filename: "icon_256x256@2x.png", size: 512),
    (filename: "icon_512x512.png", size: 512),
    (filename: "icon_512x512@2x.png", size: 1024)
]

let arguments = Array(CommandLine.arguments.dropFirst())
let preserveBackground: Bool
let sourcePath: String
let outputPath: String

if arguments.count == 2 {
    preserveBackground = false
    sourcePath = arguments[0]
    outputPath = arguments[1]
} else if arguments.count == 3 && arguments[0] == "--preserve-background" {
    preserveBackground = true
    sourcePath = arguments[1]
    outputPath = arguments[2]
} else {
    throw IconError.missingArgument
}

let sourceURL = URL(fileURLWithPath: sourcePath)
let outputURL = URL(fileURLWithPath: outputPath)
let iconsetURL = outputURL
    .deletingPathExtension()
    .appendingPathExtension("iconset")

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    throw IconError.imageLoadFailed(sourceURL.path)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSource = preserveBackground ? sourceCGImage : try makeTransparentImage(from: sourceCGImage)
let iconLayout: IconLayout = preserveBackground ? .fillSquareRounded : .paddedEmblem

for rendition in iconRenditions {
    let image = try makeIconImage(from: iconSource, size: rendition.size, layout: iconLayout)
    try writePNG(image, to: iconsetURL.appendingPathComponent(rendition.filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconsetURL.path,
    "-o",
    outputURL.path
]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw IconError.imageWriteFailed(outputURL.path)
}

func makeTransparentImage(from image: CGImage) throws -> CGImage {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.bitmapContextFailed
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var visited = [Bool](repeating: false, count: width * height)
    var stack: [(x: Int, y: Int)] = []

    func offset(x: Int, y: Int) -> Int {
        (y * width + x) * bytesPerPixel
    }

    func isBackgroundCandidate(x: Int, y: Int) -> Bool {
        let index = offset(x: x, y: y)
        let red = Int(pixels[index])
        let green = Int(pixels[index + 1])
        let blue = Int(pixels[index + 2])
        let minimum = min(red, green, blue)
        let maximum = max(red, green, blue)
        return minimum > 224 && (maximum - minimum) < 32
    }

    func enqueueIfBackground(x: Int, y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }

        let visitIndex = y * width + x
        guard !visited[visitIndex], isBackgroundCandidate(x: x, y: y) else { return }

        visited[visitIndex] = true
        stack.append((x, y))
    }

    for x in 0..<width {
        enqueueIfBackground(x: x, y: 0)
        enqueueIfBackground(x: x, y: height - 1)
    }

    for y in 0..<height {
        enqueueIfBackground(x: 0, y: y)
        enqueueIfBackground(x: width - 1, y: y)
    }

    while let point = stack.popLast() {
        let index = offset(x: point.x, y: point.y)
        pixels[index + 3] = 0

        enqueueIfBackground(x: point.x + 1, y: point.y)
        enqueueIfBackground(x: point.x - 1, y: point.y)
        enqueueIfBackground(x: point.x, y: point.y + 1)
        enqueueIfBackground(x: point.x, y: point.y - 1)
    }

    guard let transparentImage = context.makeImage() else {
        throw IconError.bitmapContextFailed
    }

    return transparentImage
}

func makeIconImage(from image: CGImage, size: Int, layout: IconLayout) throws -> CGImage {
    let dimension = CGFloat(size)
    let bytesPerPixel = 4
    let bytesPerRow = size * bytesPerPixel

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.bitmapContextFailed
    }

    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    if case .fillSquareRounded = layout {
        let iconBounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        let cornerRadius = dimension * 0.22
        context.addPath(CGPath(
            roundedRect: iconBounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.clip()
    }

    let imageAspect = CGFloat(image.width) / CGFloat(image.height)
    let drawRect: CGRect

    switch layout {
    case .paddedEmblem:
        let targetWidth = dimension * 0.92
        let targetHeight = targetWidth / imageAspect
        drawRect = CGRect(
            x: (dimension - targetWidth) / 2,
            y: (dimension - targetHeight) / 2,
            width: targetWidth,
            height: targetHeight
        )
    case .fillSquareRounded:
        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if imageAspect >= 1 {
            targetWidth = dimension * imageAspect
            targetHeight = dimension
        } else {
            targetWidth = dimension
            targetHeight = dimension / imageAspect
        }

        drawRect = CGRect(
            x: (dimension - targetWidth) / 2,
            y: (dimension - targetHeight) / 2,
            width: targetWidth,
            height: targetHeight
        )
    }

    context.draw(image, in: drawRect)

    guard let iconImage = context.makeImage() else {
        throw IconError.bitmapContextFailed
    }

    return iconImage
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.imageWriteFailed(url.path)
    }

    try data.write(to: url, options: .atomic)
}
