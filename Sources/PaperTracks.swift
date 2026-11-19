import AppKit
import SwiftUI

final class PaperScroller: NSScroller {
    var night = false { didSet { if oldValue != night { needsDisplay = true } } }
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard isEnabled else { return }
        gray(night ? 0.80 : 0.20, alpha: flag ? 0.24 : 0.13).setFill()
        thin(slotRect, thickness: 1).fill()
    }

    override func drawKnob() {
        guard isEnabled else { return }
        let rect = thin(self.rect(for: .knob), thickness: 3)
        gray(night ? 0.68 : 0.38).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    private func thin(_ rect: CGRect, thickness: CGFloat) -> CGRect {
        if bounds.width > bounds.height {
            return CGRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
        }
        return CGRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
    }
}

struct PaperScrollStyle: NSViewRepresentable {
    let axis: Axis
    let night: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.axis = axis
        view.night = night
        view.applyStyle()
    }

    final class Probe: NSView {
        var axis = Axis.vertical
        var night = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.applyStyle() }
        }

        func applyStyle() {
            guard let scroll = enclosingScrollView else { return }
            let horizontal = axis == .horizontal
            let native = horizontal ? scroll.horizontalScroller : scroll.verticalScroller
            if let existing = native as? PaperScroller {
                existing.night = night
                return
            }
            guard horizontal ? scroll.hasHorizontalScroller : scroll.hasVerticalScroller else { return }
            let frame = horizontal ? CGRect(x: 0, y: 0, width: 100, height: 12)
                                   : CGRect(x: 0, y: 0, width: 12, height: 100)
            let scroller = PaperScroller(frame: frame)
            scroller.night = night
            if horizontal { scroll.horizontalScroller = scroller }
            else { scroll.verticalScroller = scroller }
        }
    }
}

struct PaperSlider: NSViewRepresentable {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let night: Bool
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> NSSlider {
        let view = NSSlider(frame: .zero)
        view.cell = PaperSliderCell()
        view.isContinuous = true
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        return view
    }

    func updateNSView(_ view: NSSlider, context: Context) {
        context.coordinator.value = $value
        view.minValue = range.lowerBound
        view.maxValue = range.upperBound
        view.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
        view.allowsTickMarkValuesOnly = true
        view.doubleValue = value
        view.isEnabled = enabled
        view.setAccessibilityLabel(label)
        (view.cell as? PaperSliderCell)?.night = night
        view.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var value: Binding<Double>?
        @objc func changed(_ sender: NSSlider) { value?.wrappedValue = sender.doubleValue }
    }
}

private final class PaperSliderCell: NSSliderCell {
    var night = false

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let knob = knobRect(flipped: flipped)
        let inset = min(knob.width / 2, rect.width / 2)
        let track = CGRect(x: rect.minX + inset, y: knob.midY - 1, width: rect.width - 2 * inset, height: 2)
        gray(night ? 0.31 : 0.77).setFill()
        track.fill()
        let filled = min(max(knob.midX - track.minX, 0), track.width)
        PaperSwatch.rgb(0x306da7).withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        CGRect(x: track.minX, y: track.minY, width: filled, height: track.height).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let thumb = CGRect(x: knobRect.midX - 3, y: knobRect.midY - 6, width: 6, height: 12)
        gray(night ? 0.76 : 0.23, alpha: isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1, yRadius: 1).fill()
    }

    override func drawTickMarks() {}
}
