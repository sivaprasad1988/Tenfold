import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Tenfold app icon: dark squircle, notch at the top, peach equalizer bars (Theme.accent → accentDeep).
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }

// macOS icon grid: 824×824 body centred, continuous-corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(color(0.08, 0.08, 0.10)); ctx.fillPath()
ctx.restoreGState()

// Body gradient (graphite, slightly lighter at the top)
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.20, 0.20, 0.24), color(0.07, 0.07, 0.09)], [0, 1]),
                       start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
// Warm glow behind the bars
ctx.drawRadialGradient(gradient([color(0.95, 0.74, 0.52, 0.30), color(0.95, 0.74, 0.52, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 430), endRadius: 380, options: [])

// Notch: black, attached to the top edge, rounded bottom corners
let notchW: CGFloat = 330, notchH: CGFloat = 92, r: CGFloat = 40
let nx = 512 - notchW / 2, top = body.maxY
let notch = CGMutablePath()
notch.move(to: CGPoint(x: nx - 24, y: top))
notch.addQuadCurve(to: CGPoint(x: nx, y: top - 24), control: CGPoint(x: nx, y: top))   // soft shoulder
notch.addLine(to: CGPoint(x: nx, y: top - notchH + r))
notch.addQuadCurve(to: CGPoint(x: nx + r, y: top - notchH), control: CGPoint(x: nx, y: top - notchH))
notch.addLine(to: CGPoint(x: nx + notchW - r, y: top - notchH))
notch.addQuadCurve(to: CGPoint(x: nx + notchW, y: top - notchH + r), control: CGPoint(x: nx + notchW, y: top - notchH))
notch.addLine(to: CGPoint(x: nx + notchW, y: top - 24))
notch.addQuadCurve(to: CGPoint(x: nx + notchW + 24, y: top), control: CGPoint(x: nx + notchW, y: top))
notch.closeSubpath()
ctx.addPath(notch); ctx.setFillColor(color(0, 0, 0)); ctx.fillPath()
// Camera dot in the notch
ctx.setFillColor(color(0.16, 0.18, 0.24))
ctx.fillEllipse(in: CGRect(x: 512 + 92, y: top - 58, width: 22, height: 22))
ctx.restoreGState()

// Equalizer bars (peach gradient, rounded caps), bottom-aligned
let heights: [CGFloat] = [190, 330, 450, 300, 210]
let barW: CGFloat = 78, gap: CGFloat = 34
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let baseY: CGFloat = 230
let barGradient = gradient([color(0.95, 0.74, 0.52), color(0.90, 0.55, 0.38)], [0, 1])
for (i, h) in heights.enumerated() {
    let x = 512 - total / 2 + CGFloat(i) * (barW + gap)
    let rect = CGRect(x: x, y: baseY, width: barW, height: h)
    let p = CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0.95, 0.60, 0.40, 0.55))
    ctx.addPath(p); ctx.setFillColor(color(0.93, 0.65, 0.45)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(barGradient, start: CGPoint(x: x, y: rect.maxY), end: CGPoint(x: x, y: rect.minY), options: [])
    ctx.restoreGState()
}

// Subtle top highlight rim
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest), "PNG write failed")
print("wrote \(out)")
