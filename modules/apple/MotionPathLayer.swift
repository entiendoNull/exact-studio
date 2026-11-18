#if os(macOS)
import AppKit
import QuartzCore

// @ref LLP 0005#show-what-moves
final class MotionPathLayer: CALayer {
    private struct Grip { let id: String; let label: CGRect; let diamond: CGPoint; let outline: CGPath; let selected: Bool }
    private var grips: [Grip] = []

    static let teal = NSColor.systemTeal
    private static let ink = NSColor(srgbRed: 0.02, green: 0.23, blue: 0.24, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.75, green: 0.97, blue: 0.98, alpha: 1)

    func show(_ path: MotionPath?, selected: String?, video: CGRect, canvas: CGSize, scale: CGFloat) {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        grips = []
        guard let path, canvas.width > 0 else { return }
        let toView = { (u: CGPoint) in CGPoint(x: video.minX + u.x * video.width, y: video.minY + (1 - u.y) * video.height) }
        let k = video.width / canvas.width
        func outline(_ q: [CGPoint], _ radius: Double) -> CGPath {
            let v = q.map(toView)
            let r = CGRect(x: v[0].x, y: v[3].y, width: v[1].x - v[0].x, height: v[0].y - v[3].y)
            let square = abs(v[0].y - v[1].y) < 0.5 && abs(v[0].x - v[3].x) < 0.5 && abs(v[1].x - v[2].x) < 0.5 && r.width > 0 && r.height > 0
            if square {
                let c = min(CGFloat(radius) * k, r.width / 2 - 0.1, r.height / 2 - 0.1)
                return c > 0.5 ? CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil) : CGPath(rect: r, transform: nil)
            }
            let p = CGMutablePath()
            p.addLines(between: v)
            p.closeSubpath()
            return p
        }
        func shape(_ p: CGPath, stroke: NSColor?, fill: NSColor? = nil, width: CGFloat = 1.5, dash: [NSNumber]? = nil) {
            let l = CAShapeLayer()
            l.frame = bounds
            l.path = p
            l.strokeColor = stroke?.cgColor
            l.fillColor = fill?.cgColor
            l.lineWidth = width
            l.lineDashPattern = dash
            l.lineJoin = .round
            l.lineCap = .round
            addSublayer(l)
        }

        let marks = path.landings.map { (landing: $0, outline: outline($0.corners, $0.radius), selected: $0.id == selected) }
        let anySelected = marks.contains { $0.selected }
        for m in marks where !m.selected {
            shape(m.outline, stroke: NSColor.white.withAlphaComponent(anySelected ? 0.4 : 0.6), width: 1.5, dash: [6, 6])
        }
        for m in marks where m.selected {
            shape(m.outline, stroke: NSColor.white.withAlphaComponent(0.95), width: 2.2, dash: [9, 6])
        }
        shape(outline(path.now, path.nowRadius), stroke: Self.teal.withAlphaComponent(0.9), width: 1.5)

        let stops = [toView(path.start)] + marks.map { toView($0.landing.centre) }
        for (i, m) in marks.enumerated() {
            let a = stops[i], b = stops[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            guard len > 24 else { continue }
            let bend = min(len * 0.15, 48)
            let c = CGPoint(x: (a.x + b.x) / 2 - dy / len * bend, y: (a.y + b.y) / 2 + dx / len * bend)
            let ex = b.x - c.x, ey = b.y - c.y, el = max(hypot(ex, ey), 0.001)
            let end = CGPoint(x: b.x - ex / el * 12, y: b.y - ey / el * 12)
            let sx = c.x - a.x, sy = c.y - a.y, sl = max(hypot(sx, sy), 0.001)
            let begin = CGPoint(x: a.x + sx / sl * 7, y: a.y + sy / sl * 7)
            let line = CGMutablePath()
            line.move(to: begin)
            line.addQuadCurve(to: end, control: c)
            let alpha: CGFloat = m.selected ? 1 : anySelected ? 0.45 : 0.75
            shape(line, stroke: Self.teal.withAlphaComponent(alpha), width: m.selected ? 3 : 2)
            let ux = ex / el, uy = ey / el, size: CGFloat = m.selected ? 11 : 9
            let head = CGMutablePath()
            head.move(to: CGPoint(x: end.x + ux * size * 0.6, y: end.y + uy * size * 0.6))
            head.addLine(to: CGPoint(x: end.x - ux * size * 0.5 - uy * size * 0.55, y: end.y - uy * size * 0.5 + ux * size * 0.55))
            head.addLine(to: CGPoint(x: end.x - ux * size * 0.5 + uy * size * 0.55, y: end.y - uy * size * 0.5 - ux * size * 0.55))
            head.closeSubpath()
            shape(head, stroke: nil, fill: Self.teal.withAlphaComponent(alpha))
        }

        let s0 = stops[0]
        shape(CGPath(ellipseIn: CGRect(x: s0.x - 4, y: s0.y - 4, width: 8, height: 8), transform: nil), stroke: Self.teal.withAlphaComponent(0.8), fill: Self.ink.withAlphaComponent(0.6), width: 1.5)
        let now = toView(MotionPath.centre(path.now))
        shape(CGPath(ellipseIn: CGRect(x: now.x - 5, y: now.y - 5, width: 10, height: 10), transform: nil), stroke: Self.ink, fill: Self.teal, width: 2)

        var taken: [CGRect] = []
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for m in marks {
            let d = toView(m.landing.centre), h: CGFloat = m.selected ? 7.5 : 6.5
            let diamond = CGMutablePath()
            diamond.addLines(between: [CGPoint(x: d.x, y: d.y + h), CGPoint(x: d.x + h, y: d.y), CGPoint(x: d.x, y: d.y - h), CGPoint(x: d.x - h, y: d.y)])
            diamond.closeSubpath()
            shape(diamond, stroke: NSColor.black.withAlphaComponent(0.45), fill: m.selected ? .white : Self.teal.withAlphaComponent(anySelected ? 0.7 : 1), width: 1)

            let text = m.landing.label as NSString
            let size = text.size(withAttributes: [.font: font])
            let w = ceil(size.width) + 20, ht: CGFloat = 22
            let box = m.outline.boundingBoxOfPath
            var candidates = [CGRect(x: box.midX - w / 2, y: box.minY - ht - 8, width: w, height: ht),
                              CGRect(x: box.midX - w / 2, y: box.maxY + 8, width: w, height: ht)]
            for n in 1...4 { candidates.append(candidates[0].offsetBy(dx: 0, dy: CGFloat(n) * (ht + 4))) }
            let inside = bounds.insetBy(dx: 6, dy: 6)
            let fitted = candidates.map { r -> CGRect in
                CGRect(x: min(max(r.minX, inside.minX), inside.maxX - r.width), y: min(max(r.minY, inside.minY), inside.maxY - r.height), width: r.width, height: r.height)
            }
            let r = fitted.first { c in !taken.contains { $0.insetBy(dx: -3, dy: -3).intersects(c) } } ?? fitted[0]
            taken.append(r)
            let pill = CALayer()
            pill.frame = r
            pill.cornerRadius = ht / 2
            pill.backgroundColor = (m.selected ? NSColor.white : Self.ink.withAlphaComponent(anySelected ? 0.7 : 0.85)).cgColor
            let label = CATextLayer()
            label.string = NSAttributedString(string: m.landing.label, attributes: [.font: font, .foregroundColor: m.selected ? Self.ink : Self.mint])
            label.alignmentMode = .center
            label.contentsScale = scale
            label.frame = CGRect(x: 0, y: (ht - ceil(size.height)) / 2 - 0.5, width: r.width, height: ceil(size.height) + 1)
            pill.addSublayer(label)
            addSublayer(pill)
            grips.append(Grip(id: m.landing.id, label: r, diamond: d, outline: m.outline, selected: m.selected))
        }
    }

    func landing(at p: CGPoint) -> String? {
        let order = grips.filter(\.selected) + grips.filter { !$0.selected }.reversed()
        if let g = order.first(where: { $0.label.insetBy(dx: -2, dy: -2).contains(p) || hypot($0.diamond.x - p.x, $0.diamond.y - p.y) < 12 }) { return g.id }
        if let g = order.first(where: { $0.outline.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p) }) { return g.id }
        return order.first { $0.selected && $0.outline.contains(p) }?.id
    }
}
#endif
