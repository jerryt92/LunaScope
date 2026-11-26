import Foundation
import OpenCineCore
import SwiftUI

/// 常用焦段标在同一条刻度上。轻点定位，横拖细调。
struct ConsoleZoomControls: View {
    let camera: CameraController
    let limits: ConsoleZoom
    @GestureState private var gestureActive = false
    @State private var drag: Drag?
    @State private var verticalDrag = false

    var body: some View {
        let scale = drag?.scale ?? Scale(limits)
        let zoom = drag?.factor ?? camera.zoomValue
        let enabled = camera.canSet(.zoom) && !camera.processingCapture

        GeometryReader { geometry in
            let inset = 23.0
            let span = max(1, Double(geometry.size.width) - 2 * inset)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Palette.secondary.opacity(0.45))
                    .frame(width: span, height: 1)
                    .position(x: inset + span / 2, y: 33)

                if scale.continuous {
                    ForEach(0..<25) { tick in
                        Rectangle()
                            .fill(Palette.secondary.opacity(0.65))
                            .frame(width: 1, height: 4)
                            .position(x: inset + span * Double(tick) / 24, y: 33)
                    }
                }

                ForEach(scale.stops, id: \.self) { factor in
                    let selected = zoom.map { abs($0 - factor) < ConsoleZoom.step / 2 } ?? false
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(selected ? Palette.accent : Palette.secondary)
                            .frame(width: 2, height: 8)
                        Text(label(factor))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(selected ? Palette.accent : Palette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(width: 44)
                    .position(x: inset + span * scale.position(of: factor), y: 40)
                }

                if let zoom {
                    let x = inset + span * scale.position(of: zoom)
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: 2, height: 13)
                        .position(x: x, y: 30)
                    Text(label(zoom))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Palette.accent, in: Capsule())
                        .position(x: min(max(33, x), max(33, Double(geometry.size.width) - 33)), y: 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 10)
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard enabled else { return }
                    updateDrag(value, scale: scale, span: span, zoom: zoom)
                }
                .onEnded { value in
                    guard let drag else { return }
                    let position = drag.scale.position(of: drag.initial) + Double(value.translation.width) / drag.span
                    let factor = drag.scale.factor(at: position)
                    if factor != drag.initial || drag.lastSend != nil { camera.setZoom(factor) }
                    self.drag = nil
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                guard enabled, drag == nil else { return }
                let position = (Double(value.location.x) - inset) / span
                if let stop = scale.stops.min(by: { abs(scale.position(of: $0) - position) < abs(scale.position(of: $1) - position) }),
                   abs(scale.position(of: stop) - position) * span <= 15 {
                    camera.setZoom(stop)
                } else {
                    camera.setZoom(scale.factor(at: position))
                }
            })
        }
        .frame(height: 62)
        .padding(.horizontal, 4)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
        .opacity(enabled ? 1 : 0.6)
        .transaction { $0.animation = nil }
        .task(id: gestureActive) {
            // The enclosing scroll view or the system can cancel a gesture without onEnded.
            if !gestureActive {
                drag = nil
                verticalDrag = false
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("console.settings.zoom")
        .accessibilityValue(zoom.map { label($0) } ?? String(localized: "permissions.status.unknown"))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let offset: Double
            switch direction {
            case .increment: offset = 1
            case .decrement: offset = -1
            @unknown default: return
            }
            camera.setZoom(scale.adjusted(zoom, by: offset))
        }
        .accessibilityActions {
            if enabled {
                ForEach(scale.stops, id: \.self) { factor in
                    Button(label(factor)) { camera.setZoom(factor) }
                }
            }
        }
        .accessibilityIdentifier("console.zoom.fine")
    }

    private func updateDrag(_ value: DragGesture.Value, scale: Scale, span: Double, zoom: Double?) {
        guard !verticalDrag else { return }
        if drag == nil {
            guard abs(value.translation.width) > abs(value.translation.height) else {
                verticalDrag = true
                return
            }
            let initial = scale.factor(at: scale.position(of: zoom ?? scale.start))
            drag = Drag(scale: scale, span: span, initial: initial, factor: initial)
        }
        guard var editing = drag else { return }
        let position = editing.scale.position(of: editing.initial) + Double(value.translation.width) / editing.span
        let factor = editing.scale.factor(at: position)
        guard factor != editing.factor else { return }
        editing.factor = factor
        let now = ContinuousClock.now
        if editing.lastSend.map({ $0.duration(to: now) >= .milliseconds(75) }) ?? true {
            editing.lastSend = now
            camera.setZoom(factor, duringDrag: true)
        }
        drag = editing
    }

    private func label(_ factor: Double) -> String {
        "\(factor.formatted(.number.precision(.fractionLength(0...3))))×"
    }

    private struct Drag {
        let scale: Scale
        let span: Double
        let initial: Double
        var factor: Double
        var lastSend: ContinuousClock.Instant?
    }

    private struct Scale {
        let stops: [Double]
        private let anchors: [Double]
        let continuous: Bool
        var start: Double { anchors.first ?? 1 }

        init(_ limits: ConsoleZoom) {
            stops = limits.stops
            continuous = limits.fineRange != nil
            if let range = limits.fineRange {
                anchors = Set(stops + [range.lowerBound, range.upperBound]).sorted()
            } else {
                anchors = stops
            }
        }

        // Equal space between successive presets keeps the shortcuts tappable on narrow screens.
        func position(of factor: Double) -> Double {
            guard anchors.count > 1, factor > start else { return 0 }
            guard let upper = anchors.firstIndex(where: { $0 >= factor }) else { return 1 }
            let fraction = (factor - anchors[upper - 1]) / (anchors[upper] - anchors[upper - 1])
            return (Double(upper - 1) + fraction) / Double(anchors.count - 1)
        }

        func factor(at position: Double) -> Double {
            guard anchors.count > 1 else { return start }
            let index = min(1, max(0, position)) * Double(anchors.count - 1)
            if !continuous { return anchors[Int(index.rounded())] }
            let lower = min(Int(index), anchors.count - 2)
            let factor = anchors[lower] + (anchors[lower + 1] - anchors[lower]) * (index - Double(lower))
            return ConsoleZoom.quantize(factor)
        }

        func adjusted(_ zoom: Double?, by offset: Double) -> Double {
            let position = position(of: zoom ?? start)
            if !continuous { return factor(at: position + offset / Double(max(1, anchors.count - 1))) }
            let current = factor(at: position)
            return factor(at: self.position(of: current + offset * ConsoleZoom.step))
        }
    }
}
