#if os(macOS)
import CoreGraphics
import Foundation

// @ref LLP 0005#show-what-moves
struct MotionPath: Equatable {
    struct Landing: Equatable {
        var id: String
        var number: Int
        var t: Double
        var style: String
        var corners: [CGPoint]
        var radius: Double

        var centre: CGPoint { MotionPath.centre(corners) }
        var label: String { "\(number) · \(MotionPath.styleName(style)) · \(MotionPath.stamp(t))" }
    }

    var start: CGPoint
    var now: [CGPoint]
    var nowRadius: Double
    var landings: [Landing]

    static func centre(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.map(\.x).reduce(0, +) / CGFloat(max(q.count, 1)), y: q.map(\.y).reduce(0, +) / CGFloat(max(q.count, 1)))
    }

    static func bounds(_ q: [CGPoint]) -> CGRect {
        let xs = q.map(\.x), ys = q.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func styleName(_ style: String) -> String {
        ["smooth": "Smooth", "linear": "Linear", "spring": "Spring", "zoom": "Zoom through", "swipe": "Swipe",
         "fade": "Fade", "spin": "Spin", "pop": "Pop"][style] ?? style.capitalized
    }

    static func stamp(_ t: Double) -> String {
        let s = max(t, 0)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

extension Framing {
    func motionPath(at playhead: Double) -> MotionPath? {
        let moves = edits.moves.sorted { $0.t < $1.t }
        guard let first = moves.first else { return nil }
        let landings = moves.enumerated().map { i, m in
            MotionPath.Landing(id: m.id, number: i + 1, t: m.t, style: m.style, corners: subjectCorners(at: m.t), radius: subjectRadius(at: m.t))
        }
        return MotionPath(start: MotionPath.centre(subjectCorners(at: max(0, first.t - first.duration))),
                          now: subjectCorners(at: playhead), nowRadius: subjectRadius(at: playhead), landings: landings)
    }

    func motionPath(image s: Segment, at playhead: Double) -> MotionPath? {
        let moves = (s.moves ?? []).sorted { $0.t < $1.t }
        guard let first = moves.first else { return nil }
        let landings = moves.enumerated().map { i, m in
            MotionPath.Landing(id: m.id, number: i + 1, t: m.t, style: m.style, corners: imageCorners(s, at: m.t), radius: imageRadius(s, at: m.t))
        }
        return MotionPath(start: MotionPath.centre(imageCorners(s, at: max(s.start, first.t - first.duration))),
                          now: imageCorners(s, at: playhead), nowRadius: imageRadius(s, at: playhead), landings: landings)
    }

    func subjectCorners(at t: Double) -> [CGPoint] {
        let p = pose(at: t)
        let place = placement(p)
        let face = [CGPoint(x: subject.minX, y: subject.maxY), CGPoint(x: subject.maxX, y: subject.maxY),
                    CGPoint(x: subject.maxX, y: subject.minY), CGPoint(x: subject.minX, y: subject.minY)]
        let drawn = turned(p) ? face.map { projected($0, angles: p.angles) } : face
        var placed = drawn.map { $0.applying(place) }
        let (s, c) = camera(at: t, place: place)
        if abs(s - 1) > 0.0005 {
            let zoom = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
            placed = placed.map { $0.applying(zoom) }
        }
        return placed.map { CGPoint(x: $0.x / canvas.width, y: 1 - $0.y / canvas.height) }
    }

    func subjectRadius(at t: Double) -> Double {
        let p = pose(at: t)
        guard !turned(p) else { return 0 }
        let r: CGFloat
        if meta.isDevice { r = CGFloat(meta.cornerRadius ?? 0.16) * subject.width }
        else if meta.isWindow, let w = meta.cornerRadius { r = CGFloat(w) * subject.width }
        else { r = CGFloat(look.radius) }
        let (s, _) = camera(at: t, place: placement(p))
        return Double(max(0, min(r, min(subject.width, subject.height) / 2))) * p.scale * Double(s)
    }

    func imageCorners(_ s: Segment, at t: Double) -> [CGPoint] {
        let p = imagePose(s, at: t)
        let box = imageFrame(s, at: t)
        let cx = (box.x + box.w / 2) * canvas.width, cy = (box.y + box.h / 2) * canvas.height
        let hw = box.w * canvas.width / 2, hh = box.h * canvas.height / 2
        let a = ((s.rotation ?? 0) + p.rotation) * .pi / 180
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
            CGPoint(x: (cx + dx * cos(a) - dy * sin(a)) / canvas.width, y: (cy + dx * sin(a) + dy * cos(a)) / canvas.height)
        }
    }

    func imageRadius(_ s: Segment, at t: Double) -> Double {
        let box = imageFrame(s, at: t)
        return min(s.radius ?? 0, 0.5) * min(box.w * canvas.width, box.h * canvas.height)
    }

    private func turned(_ p: Pose) -> Bool {
        abs(p.angles.tilt) + abs(p.angles.turn.truncatingRemainder(dividingBy: 360)) + abs(p.angles.roll) > 0.01
    }

    // @ref LLP 0003#real-3d — the same euler order, camera distance and field of view as Stage3D
    private func projected(_ q: CGPoint, angles: Angles) -> CGPoint {
        let x0 = Double(q.x - subject.midX), y0 = Double(q.y - subject.midY)
        let pitch = -angles.tilt * .pi / 180, yaw = angles.turn * .pi / 180, roll = -angles.roll * .pi / 180
        let x1 = x0, y1 = y0 * cos(pitch), z1 = y0 * sin(pitch)
        let x2 = x1 * cos(yaw) + z1 * sin(yaw), y2 = y1, z2 = -x1 * sin(yaw) + z1 * cos(yaw)
        let x3 = x2 * cos(roll) - y2 * sin(roll), y3 = x2 * sin(roll) + y2 * cos(roll)
        let at = (x: x3 + Double(subject.midX - canvas.width / 2), y: y3 + Double(subject.midY - canvas.height / 2))
        let distance = Double(canvas.height / 2) / tan(Double(Stage3D.fov) / 2 * .pi / 180)
        let k = distance / max(distance - z2, 1)
        return CGPoint(x: canvas.width / 2 + CGFloat(at.x * k), y: canvas.height / 2 + CGFloat(at.y * k))
    }
}
#endif
