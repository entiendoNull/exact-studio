// Draws assets/icon-1024.png with the app's own 3D renderer:
//   swiftc -O -o .exact/make-icon tools/make-icon.swift modules/apple/{Scene3D,Compositor,Bezel}.swift && .exact/make-icon assets/icon-1024.png
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
_ = NSApplication.shared
let N = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func ctx(_ w: Int, _ h: Int) -> CGContext {
  CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ h: Int, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: a) }

// The phone's screen: a bright gradient, a dynamic island, a play mark.
let pw = 262, ph = 540
let sc = ctx(pw, ph)
let screen = CGRect(x: 0, y: 0, width: pw, height: ph)
sc.addPath(CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)); sc.clip()
let g = CGGradient(colorsSpace: space, colors: [rgb(0x4AE3C8), rgb(0x3D7BFF), rgb(0x8B3DFF)] as CFArray, locations: [0, 0.55, 1])!
sc.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(ph)), end: CGPoint(x: CGFloat(pw), y: 0), options: [])
// Bezel ring drawn on the face so the screen sits inside a black border.
sc.setStrokeColor(rgb(0x0B0C12)); sc.setLineWidth(21); sc.addPath(CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)); sc.strokePath()
sc.setFillColor(rgb(0x0B0C12)); sc.addPath(CGPath(roundedRect: CGRect(x: pw/2-42, y: ph-50, width: 84, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)); sc.fillPath()
// A play mark, soft white.
let cx = CGFloat(pw)/2 + 8, cy = CGFloat(ph)/2
sc.setFillColor(CGColor(gray: 1, alpha: 0.92))
let tri = CGMutablePath(); tri.move(to: CGPoint(x: cx-30, y: cy+42)); tri.addLine(to: CGPoint(x: cx+40, y: cy)); tri.addLine(to: CGPoint(x: cx-30, y: cy-42)); tri.closeSubpath()
sc.addPath(tri); sc.fillPath()
let faceCG = sc.makeImage()!

// The phone in 3D, with the app's own renderer.
let canvas = CGSize(width: N, height: N)
let rect = CGRect(x: (N - pw)/2, y: (N - ph)/2 - 6, width: pw, height: ph)
let face = CIImage(cgImage: faceCG).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
var three = ThreeD(); three.on = true; three.tilt = 14; three.turn = -26; three.roll = -6; three.thickness = 0.075; three.edge = "metal"
let outline = CGPath(roundedRect: rect, cornerWidth: 46, cornerHeight: 46, transform: nil)
let buttons = [CGRect(x: rect.minX - 6, y: rect.midY + 72, width: 8, height: 56), CGRect(x: rect.minX - 6, y: rect.midY + 2, width: 8, height: 56), CGRect(x: rect.maxX - 2, y: rect.midY + 24, width: 8, height: 90)]
let phone = Stage3D.shared.render(face: face, rect: rect, outline: outline, buttons: buttons, canvas: canvas, three: three, scale: 2)!
let ci = CIContext()
let phoneCG = ci.createCGImage(phone, from: CGRect(origin: .zero, size: canvas))!
let shadow = ci.createCGImage(phone.applyingGaussianBlur(sigma: 28).cropped(to: CGRect(origin: .zero, size: canvas)), from: CGRect(origin: .zero, size: canvas))!

// The icon: Apple's grid, an 824 px rounded square on 1024.
let c = ctx(N, N)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
c.saveGState(); c.addPath(squircle); c.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2B2F6E), rgb(0x161634), rgb(0x0C0D1E)] as CFArray, locations: [0, 0.6, 1])!
c.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(N)), end: CGPoint(x: CGFloat(N) * 0.7, y: 0), options: [])
// A soft glow behind the phone.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5B7CFF, 0.55), rgb(0x5B7CFF, 0)] as CFArray, locations: [0, 1])!
c.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 400, options: [])
// Crop brackets: the exact frame around the device.
c.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); c.setLineWidth(22); c.setLineCap(.round); c.setLineJoin(.round)
let f = CGRect(x: 232, y: 188, width: 560, height: 648), arm: CGFloat = 96
for (p, dx, dy) in [(CGPoint(x: f.minX, y: f.maxY), 1.0, -1.0), (CGPoint(x: f.minX, y: f.minY), 1.0, 1.0), (CGPoint(x: f.maxX, y: f.minY), -1.0, 1.0)] {
  c.move(to: CGPoint(x: p.x, y: p.y + CGFloat(dy) * arm)); c.addLine(to: p); c.addLine(to: CGPoint(x: p.x + CGFloat(dx) * arm, y: p.y)); c.strokePath()
}
// The phone over its shadow.
c.saveGState(); c.setAlpha(0.6); c.translateBy(x: 14, y: -26); c.draw(shadow, in: CGRect(origin: .zero, size: canvas)); c.restoreGState()
c.draw(phoneCG, in: CGRect(origin: .zero, size: canvas))
// The record dot, top right, with a ring.
let dot = CGPoint(x: f.maxX - 30, y: f.maxY - 30)
c.setFillColor(rgb(0xFF3B47)); c.fillEllipse(in: CGRect(x: dot.x - 46, y: dot.y - 46, width: 92, height: 92))
c.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); c.setLineWidth(12); c.strokeEllipse(in: CGRect(x: dot.x - 58, y: dot.y - 58, width: 116, height: 116))
c.restoreGState()
// A hairline on the edge, as Apple's icons have.
c.addPath(squircle); c.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); c.setLineWidth(3); c.strokePath()
let out = c.makeImage()!
try! NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
