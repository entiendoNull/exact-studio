// The subject in 3D: its outline extruded into a slab, the finished 2D frame
// of the subject (effects and cursor drawn) on its front face, lit and seen
// through a perspective camera. The camera is placed so that a slab facing
// it square covers exactly the pixels the flat subject would: turning 3D on
// at zero angles changes nothing, and only a turn shows its depth.
//
// One renderer for the process, behind a lock: the compositor may ask from
// more than one thread. No Exact types here: a test harness compiles it alone.
#if os(macOS)
import AppKit
import CoreImage
import SceneKit

/// What 3D the person chose for a recording.
struct ThreeD: Codable, Equatable {
    var on = false
    /// Degrees: `tilt` leans the top away, `turn` swings the right side away, `roll` turns it flat.
    var tilt = 0.0, turn = 0.0, roll = 0.0
    /// The slab's depth as a share of its width.
    var thickness = 0.05
    /// The edge's finish: "metal", "aluminum", "glass" or "matte".
    var edge = "metal"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThreeD()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        tilt = try c.decodeIfPresent(Double.self, forKey: .tilt) ?? d.tilt
        turn = try c.decodeIfPresent(Double.self, forKey: .turn) ?? d.turn
        roll = try c.decodeIfPresent(Double.self, forKey: .roll) ?? d.roll
        thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? d.thickness
        edge = try c.decodeIfPresent(String.self, forKey: .edge) ?? d.edge
    }
}

final class Stage3D {
    static let shared = Stage3D()

    private let lock = NSLock()
    private let renderer: SCNRenderer
    private let scene = SCNScene()
    private let camera = SCNNode()
    private let slab = SCNNode()
    private var shapeKey = ""
    private let front = SCNMaterial(), back = SCNMaterial(), side = SCNMaterial(), chamfer = SCNMaterial()
    private let images = CIContext()
    static let fov: CGFloat = 30

    private init() {
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        scene.background.contents = NSColor.clear
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = Stage3D.fov
        camera.camera!.projectionDirection = .vertical
        camera.camera!.zNear = 1
        camera.camera!.zFar = 100_000
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
        scene.rootNode.addChildNode(slab)

        // Studio light: a soft fill, a key from the upper left, a rim from behind on the right.
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 350
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, -0.5, 0)
        let rim = SCNNode(); rim.light = SCNLight(); rim.light!.type = .directional; rim.light!.intensity = 500
        rim.eulerAngles = SCNVector3(0.3, 2.4, 0)
        [ambient, key, rim].forEach(scene.rootNode.addChildNode)
        scene.lightingEnvironment.contents = Stage3D.studio()
        scene.lightingEnvironment.intensity = 1.2

        // The screen is the recording: shown as it is, unlit.
        front.lightingModel = .constant
        front.isDoubleSided = false
        back.lightingModel = .physicallyBased
        back.diffuse.contents = NSColor(white: 0.08, alpha: 1)
        back.roughness.contents = 0.6
        [side, chamfer].forEach { $0.lightingModel = .physicallyBased }
    }

    /// A soft studio for reflections: a bright band overhead fading to dark below.
    private static func studio() -> CGImage {
        let w = 512, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.05, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.25, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        return ctx.makeImage()!
    }

    private func finish(_ edge: String) {
        let (color, metal, rough): (NSColor, Double, Double)
        switch edge {
        case "aluminum": (color, metal, rough) = (NSColor(white: 0.78, alpha: 1), 1, 0.45)
        case "glass": (color, metal, rough) = (NSColor(white: 0.9, alpha: 1), 0, 0.05)
        case "matte": (color, metal, rough) = (NSColor(white: 0.16, alpha: 1), 0, 0.8)
        default: (color, metal, rough) = (NSColor(white: 0.32, alpha: 1), 1, 0.28)
        }
        for m in [side, chamfer] {
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
        }
    }

    /// The slab for an outline (in canvas pixels, centred on the origin), made again only when it changes.
    private func shape(_ outline: CGPath, size: CGSize, depth: CGFloat) {
        let key = "\(size.width)x\(size.height)|\(depth)|\(outline.boundingBox)|\(outline.hashValue)"
        guard key != shapeKey else { return }
        shapeKey = key
        let path = NSBezierPath(cgPath: outline)
        path.flatness = 0.3
        let s = SCNShape(path: path, extrusionDepth: depth)
        s.chamferRadius = min(depth * 0.45, size.width * 0.02)
        s.chamferMode = .both
        s.materials = [front, back, side, chamfer, chamfer]
        slab.geometry = s
    }

    private var buttonKey = ""

    /// The side buttons: rounded metal pieces, set into the middle of the body's depth and
    /// standing out from its edge by the width the silhouette shows.
    private func place(_ buttons: [CGRect], around rect: CGRect, depth: CGFloat) {
        let key = "\(buttons)|\(rect.size)|\(depth)"
        guard key != buttonKey else { return }
        buttonKey = key
        slab.childNodes.forEach { $0.removeFromParentNode() }
        for b in buttons {
            // Sunk a little into the body so no gap shows at an angle.
            let sink = min(b.width, depth * 0.3)
            let box = SCNBox(width: b.width + sink, height: b.height, length: depth * 0.42, chamferRadius: min(b.width, depth * 0.2) * 0.9)
            // The edge's own material, so a change of finish reaches the buttons too.
            box.materials = [side]
            let node = SCNNode(geometry: box)
            let leftSide = b.midX < rect.midX
            let cx = (leftSide ? b.minX + (b.width + sink) / 2 : b.maxX - (b.width + sink) / 2) - rect.midX
            // In the slab's geometry its middle depth is z = 0.
            node.position = SCNVector3(cx, b.midY - rect.midY, 0)
            slab.addChildNode(node)
        }
    }

    /// The subject turned in 3D, as an image the size of the canvas (transparent around it).
    /// `face` is the subject's finished picture over `rect` (its place on the canvas, Core Image coordinates);
    /// `outline` is the slab's shape in the same coordinates.
    /// `buttons` stand out from the body's sides (a device's), in the same coordinates.
    func render(face: CIImage, rect: CGRect, outline: CGPath, buttons: [CGRect] = [], canvas: CGSize, three: ThreeD, scale: CGFloat = 1) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        // The face as a texture, exactly the slab's front.
        guard let tex = images.createCGImage(face, from: rect) else { return nil }
        front.diffuse.contents = tex
        finish(three.edge)

        // The outline about the subject's centre, in scene units of one canvas pixel.
        var centre = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
        guard let local = outline.copy(using: &centre) else { return nil }
        let depth = max(1, CGFloat(three.thickness) * rect.width)
        shape(local, size: rect.size, depth: depth)
        place(buttons, around: rect, depth: depth)
        // SCNShape spans its front face's texture over the outline's bounding box; keep it on the subject's rectangle.
        let bb = local.boundingBox
        front.diffuse.contentsTransform = SCNMatrix4MakeScale(rect.width / max(bb.width, 1), rect.height / max(bb.height, 1), 1)

        // The front face sits at z = 0 so it matches the flat picture; the body extends behind.
        // The node's origin is the front face's centre, so it turns about the face.
        slab.position = SCNVector3(rect.midX - canvas.width / 2, rect.midY - canvas.height / 2, 0)
        slab.pivot = SCNMatrix4MakeTranslation(0, 0, depth / 2)
        // Positive tilt leans the top away; positive turn swings the right side away; positive roll is clockwise.
        slab.eulerAngles = SCNVector3(-CGFloat(three.tilt) * .pi / 180, CGFloat(three.turn) * .pi / 180, -CGFloat(three.roll) * .pi / 180)

        // The camera at the distance where the canvas fills its view.
        let distance = (canvas.height / 2) / tan(Stage3D.fov / 2 * .pi / 180)
        camera.position = SCNVector3(0, 0, distance)

        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let shot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        guard let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var out = CIImage(cgImage: cg)
        if scale != 1 { out = out.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)) }
        return out
    }
}
#endif
