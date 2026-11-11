// `<studio-color hex="#RRGGBB" change=…>`: AppKit's colour well, which opens
// the system's colour picker; `change` hands the chosen colour as "#RRGGBB".
#if os(macOS)
import AppKit

final class ColorWell: ExactNativeInstance {
    private let well = NSColorWell(style: .expanded)
    private var hex = ""

    init(_ props: [String: String], _ events: ExactNativeEvents) {
        super.init(events: events)
        well.target = self
        well.action = #selector(picked)
        try? setProps(props)
        events.intrinsicSize(CGSize(width: 64, height: 28))
    }

    override var view: ExactNativeView { well }
    override var focusTarget: ExactNativeView? { well }

    override func setProps(_ props: [String: String]) throws {
        let next = props["hex"] ?? "#000000"
        guard next != hex else { return }
        hex = next
        if let c = Backgrounds.hex(next) { well.color = NSColor(ciColor: c) }
    }

    /// The agent's `type <well> #RRGGBB` picks that colour, as the person would in the panel.
    override func agentInput(_ input: ExactNativeInput) throws {
        guard case let .text(t) = input, let c = Backgrounds.hex(t) else { throw ExactNativeRefusal("studio-color takes a colour as #RRGGBB") }
        well.color = NSColor(ciColor: c)
        picked()
    }

    @objc private func picked() {
        guard let c = well.color.usingColorSpace(.sRGB) else { return }
        let v = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        guard v != hex else { return }
        hex = v
        events.change(v)
    }
}
#endif
