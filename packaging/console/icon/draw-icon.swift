// Draws the imctl app icon (macOS squircle, chat bubble + control chevron) at one size.
// Usage: swift draw-icon.swift <size> <out.png>
import AppKit
import CoreGraphics

let size = Int(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let s = CGFloat(size)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

// macOS icon grid: the squircle fills ~82% of the canvas.
let inset = s * 0.09
let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let radius = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// background: deep blue → teal gradient
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let colors = [CGColor(red: 0.07, green: 0.29, blue: 0.62, alpha: 1), CGColor(red: 0.05, green: 0.62, blue: 0.62, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// subtle top sheen
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
ctx.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
ctx.restoreGState()

// chat bubble (white), tail bottom-left
let bw = rect.width * 0.62, bh = rect.height * 0.46
let bx = rect.midX - bw / 2, by = rect.midY - bh / 2 + rect.height * 0.06
let bubble = CGMutablePath()
bubble.addRoundedRect(in: CGRect(x: bx, y: by, width: bw, height: bh), cornerWidth: bh * 0.28, cornerHeight: bh * 0.28)
bubble.move(to: CGPoint(x: bx + bw * 0.16, y: by + bh * 0.05))
bubble.addLine(to: CGPoint(x: bx + bw * 0.08, y: by - bh * 0.22))
bubble.addLine(to: CGPoint(x: bx + bw * 0.34, y: by + bh * 0.05))
bubble.closeSubpath()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
ctx.addPath(bubble); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// control chevron ">" and a cursor bar inside the bubble (the terminal / controller idea)
ctx.setStrokeColor(CGColor(red: 0.06, green: 0.32, blue: 0.62, alpha: 1))
ctx.setLineWidth(bh * 0.13); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let cx = bx + bw * 0.24, cy = by + bh * 0.5, ch = bh * 0.34
ctx.move(to: CGPoint(x: cx, y: cy + ch / 2)); ctx.addLine(to: CGPoint(x: cx + ch * 0.6, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy - ch / 2))
ctx.strokePath()
ctx.setFillColor(CGColor(red: 0.05, green: 0.62, blue: 0.62, alpha: 1))
ctx.fill(CGRect(x: cx + ch * 0.95, y: cy - ch * 0.5, width: bw * 0.32, height: bh * 0.13).insetBy(dx: 0, dy: 0))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
