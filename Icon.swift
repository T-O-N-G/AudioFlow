import AppKit

let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.30, alpha: 1).setFill()
background.fill()

let shape = NSBezierPath()
shape.move(to: NSPoint(x: 207, y: 514))
shape.line(to: NSPoint(x: 315, y: 514))
shape.curve(to: NSPoint(x: 416, y: 514), controlPoint1: NSPoint(x: 358, y: 514), controlPoint2: NSPoint(x: 367, y: 718))
shape.curve(to: NSPoint(x: 526, y: 514), controlPoint1: NSPoint(x: 464, y: 310), controlPoint2: NSPoint(x: 476, y: 514))
shape.curve(to: NSPoint(x: 635, y: 514), controlPoint1: NSPoint(x: 576, y: 718), controlPoint2: NSPoint(x: 587, y: 514))
shape.line(to: NSPoint(x: 727, y: 514))
shape.lineWidth = 68
shape.lineCapStyle = .round
shape.lineJoinStyle = .round
NSColor(calibratedRed: 0.48, green: 0.89, blue: 0.87, alpha: 1).setStroke()
shape.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 698, y: 630))
arrow.line(to: NSPoint(x: 814, y: 514))
arrow.line(to: NSPoint(x: 698, y: 398))
arrow.lineWidth = 60
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.97, alpha: 1).setStroke()
arrow.stroke()
image.unlockFocus()

var iconChunks = Data()
for (filename, pixels) in [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)] {
    let resized = NSImage(size: NSSize(width: pixels, height: pixels))
    resized.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    resized.unlockFocus()
    guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
    try png.write(to: iconset.appendingPathComponent(filename))
    if pixels == 1024 { try png.write(to: resources.appendingPathComponent("AppIcon.png")) }
    if let type = [16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"][pixels], filename.hasSuffix("@2x.png") || ![32, 256, 512].contains(pixels) {
        iconChunks.append(contentsOf: type.utf8)
        var length = UInt32(png.count + 8).bigEndian
        withUnsafeBytes(of: &length) { iconChunks.append(contentsOf: $0) }
        iconChunks.append(png)
    }
}
var icns = Data("icns".utf8)
var totalLength = UInt32(iconChunks.count + 8).bigEndian
withUnsafeBytes(of: &totalLength) { icns.append(contentsOf: $0) }
icns.append(iconChunks)
try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
try FileManager.default.removeItem(at: iconset)
