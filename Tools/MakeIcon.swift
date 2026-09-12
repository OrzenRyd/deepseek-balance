// 生成 App 图标（.iconset），供 iconutil 打包成 .icns
// 用法： makeicon <输出目录>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func png(size: Int) -> Data? {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }

    let inset = max(1, s * 0.05)
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(srgbRed: 0.35, green: 0.48, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.14, blue: 0.40, alpha: 1).cgColor,
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // 右下角一点绿色，暗示「谷值」
    ctx.saveGState()
    ctx.setFillColor(NSColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 1).cgColor)
    let dot = s * 0.15
    ctx.fillEllipse(in: CGRect(x: s - inset - dot * 1.05, y: inset + dot * 0.05, width: dot, height: dot))
    ctx.restoreGState()

    let font = NSFont.systemFont(ofSize: s * 0.60, weight: .bold)
    let str = NSAttributedString(string: "¥", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
    ])
    let bounds = str.size()
    str.draw(at: NSPoint(x: (s - bounds.width) / 2, y: (s - bounds.height) / 2 + s * 0.02))

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var ok = true
for v in variants {
    guard let data = png(size: v.size) else { ok = false; continue }
    let target = iconset + "/" + v.name
    if (try? data.write(to: URL(fileURLWithPath: target))) == nil { ok = false }
}

print(ok ? "iconset written to \(iconset)" : "icon generation had failures")
exit(ok ? 0 : 1)
