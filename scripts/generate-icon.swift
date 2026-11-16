import AppKit

// Build a compact, original app icon without any downloaded assets.
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 0.89, green: 0.95, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.25, green: 0.61, blue: 0.94, alpha: 1))!.draw(in: bg, angle: 90)

func rr(_ r: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}
let dark = NSColor(calibratedRed: 0.14, green: 0.21, blue: 0.31, alpha: 1)
let white = NSColor(calibratedWhite: 0.98, alpha: 1)
rr(NSRect(x: 125, y: 265, width: 774, height: 462), 72, dark)
rr(NSRect(x: 140, y: 310, width: 740, height: 400), 62, white)
rr(NSRect(x: 174, y: 618, width: 670, height: 130), 30, dark)
rr(NSRect(x: 230, y: 735, width: 560, height: 78), 20, NSColor(calibratedWhite: 0.97, alpha: 1))
rr(NSRect(x: 210, y: 378, width: 605, height: 52), 12, dark)
rr(NSRect(x: 267, y: 390, width: 490, height: 21), 10, NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.94, alpha: 1))
rr(NSRect(x: 530, y: 507, width: 214, height: 76), 22, NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.88, alpha: 1))
rr(NSRect(x: 300, y: 190, width: 440, height: 180), 8, white)
for i in 0..<4 {
    rr(NSRect(x: 340, y: 318 - i * 27, width: i == 0 ? 210 : 290, height: 9), 4, NSColor(calibratedWhite: 0.72, alpha: 1))
}
for (i,h) in [38.0,67.0,90.0].enumerated() {
    rr(NSRect(x: CGFloat(570 + i * 43), y: 217, width: 29, height: h), 3, NSColor(calibratedRed: 0.08, green: 0.5 + CGFloat(i)*0.08, blue: 0.9, alpha: 1))
}
image.unlockFocus()
let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
