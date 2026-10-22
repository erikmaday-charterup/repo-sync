// Draws the 1024pt Repo Sync app icon to the PNG path given as the first argument.
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
let plateTop = rgb(0x4F8EF7)
let plateBottom = rgb(0x1F57D6)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Apple's macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    plateBottom.setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: platePath, angle: -90)

    // Three stacked repo cards stepping toward the lower right, with a down arrow on the front one.
    let cardSize = NSSize(width: 430, height: 330)
    let step = CGPoint(x: 62, y: -62)
    let origin = CGPoint(x: plate.midX - cardSize.width / 2 - step.x, y: plate.midY - cardSize.height / 2 - step.y + 6)
    for i in 0..<3 {
        let rect = NSRect(x: origin.x + step.x * CGFloat(i), y: origin.y + step.y * CGFloat(i), width: cardSize.width, height: cardSize.height)
        let isFront = i == 2
        (isFront ? NSColor.white : NSColor.white.withAlphaComponent(0.55)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 54, yRadius: 54).fill()
        guard isFront else { continue }
        let arrow = NSBezierPath()
        arrow.lineWidth = 38
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: CGPoint(x: rect.midX, y: rect.midY + 92))
        arrow.line(to: CGPoint(x: rect.midX, y: rect.midY - 82))
        arrow.move(to: CGPoint(x: rect.midX - 78, y: rect.midY - 6))
        arrow.line(to: CGPoint(x: rect.midX, y: rect.midY - 84))
        arrow.line(to: CGPoint(x: rect.midX + 78, y: rect.midY - 6))
        plateBottom.setStroke()
        arrow.stroke()
    }
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: out)
