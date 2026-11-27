import Foundation
import OpenCineCore
import SwiftUI

/// 取景下方的变焦条：预设等宽排列，滑块位置跟手指。落点精确到 0.1，预设两侧 ±0.2 的手指路程更宽。
struct ConsoleZoomControls: View {
    /// 横屏布局按这个高度给变焦留空。
    static let barHeight: CGFloat = 80
    let camera: CameraController
    let limits: ConsoleZoom
    @GestureState private var gestureActive = false
    @State private var drag: Drag?

    var body: some View {
        let scale = Scale(limits)
        let zoom = drag?.factor ?? camera.zoomValue
        let enabled = camera.canSet(.zoom) && !camera.processingCapture

        GeometryReader { geometry in
            let width = Double(geometry.size.width)
            let pitch = width / Double(max(scale.anchors.count, 1))
            let inset = pitch / 2
            let span = max(1, width - pitch)
            let thumbX = zoom.map { inset + span * scale.position(of: $0) }
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Palette.secondary.opacity(0.28))
                    .frame(width: span, height: 6)
                    .position(x: width / 2, y: 38)
                if let thumbX {
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: max(6, thumbX - inset), height: 6)
                        .position(x: inset + max(6, thumbX - inset) / 2, y: 38)
                }
                ForEach(scale.stops, id: \.self) { factor in
                    let x = inset + span * scale.position(of: factor)
                    let selected = zoom.map { abs($0 - factor) < Self.tenth / 2 } ?? false
                    Circle()
                        .fill(selected ? Palette.accent : Palette.field)
                        .overlay {
                            Circle().strokeBorder(selected ? Palette.accent : Palette.secondary, lineWidth: 2.5)
                        }
                        .frame(width: 16, height: 16)
                        .position(x: x, y: 38)
                    Text(stopLabel(factor))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? Palette.accent : Palette.secondary)
                        .lineLimit(1)
                        .frame(width: pitch)
                        .position(x: x, y: 60)
                }
                // 滑块在预设点上和在中间倍数上一样大，盖在预设圆点上面。
                if let thumbX {
                    Circle()
                        .fill(Palette.accent)
                        .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
                        .frame(width: 22, height: 22)
                        .position(x: thumbX, y: 38)
                }
                if let zoom, let thumbX {
                    Text(valueLabel(zoom))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accent, in: Capsule())
                        .position(x: min(max(34, thumbX), max(34, width - 34)), y: 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard enabled else { return }
                    let position = (Double(value.location.x) - inset) / span
                    follow(scale.factor(at: position, snap: Self.tapSnap(value) / span), preview: true)
                }
                .onEnded { value in
                    guard enabled else { return }
                    let position = (Double(value.location.x) - inset) / span
                    let factor = scale.factor(at: position, snap: Self.tapSnap(value) / span)
                    drag = Drag(factor: factor, lastSend: drag?.lastSend)
                    camera.setZoom(factor)
                    drag = nil
                })
        }
        .frame(height: Self.barHeight)
        .padding(.horizontal, 4)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
        .opacity(enabled ? 1 : 0.6)
        .transaction { $0.animation = nil }
        .task(id: gestureActive) {
            if !gestureActive { drag = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("console.settings.zoom")
        .accessibilityValue(zoom.map { valueLabel($0) } ?? String(localized: "permissions.status.unknown"))
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
                    Button(valueLabel(factor)) { camera.setZoom(factor) }
                }
            }
        }
        .accessibilityIdentifier("console.zoom.fine")
        .sensoryFeedback(trigger: drag?.factor) { previous, next in
            guard let next, next != previous else { return nil }
            return Self.feedback(for: next, stops: limits.stops)
        }
    }

    /// 点按时吸到附近预设的半径；手指一拖开就不再吸附，±0.1、±0.2 才不会被吸走。
    private static func tapSnap(_ value: DragGesture.Value) -> Double {
        hypot(value.translation.width, value.translation.height) < 6 ? 18 : 0
    }

    /// 预设点给明确一击，两侧 0.1 和 0.2 各轻震一下。
    private static func feedback(for factor: Double, stops: [Double]) -> SensoryFeedback? {
        guard let delta = stops.map({ abs($0 - factor) }).min() else { return nil }
        if delta < tenth / 2 { return .impact(weight: .medium, intensity: 1) }
        if delta < 0.25 { return .selection }
        return nil
    }

    /// 数轴一格是 0.1。
    private static let tenth = 0.1

    /// 手指所在位置立即反映到滑块；发给相机的预览写入仍按 75ms 节流。
    private func follow(_ factor: Double, preview: Bool) {
        let changed = drag?.factor != factor
        var editing = drag ?? Drag(factor: factor)
        editing.factor = factor
        let now = ContinuousClock.now
        if changed, editing.lastSend.map({ $0.duration(to: now) >= .milliseconds(75) }) ?? true {
            editing.lastSend = now
            camera.setZoom(factor, duringDrag: preview)
        }
        drag = editing
    }

    private func stopLabel(_ factor: Double) -> String {
        "\(factor.formatted(.number.precision(.fractionLength(0...1))))×"
    }

    private func valueLabel(_ factor: Double) -> String {
        "\(factor.formatted(.number.precision(.fractionLength(1))))×"
    }

    private struct Drag {
        var factor: Double
        var lastSend: ContinuousClock.Instant?
    }

    /// 预设等距铺满整条，位置不变。相邻预设之间，两端靠近预设的一小段占更宽的手指路程，
    /// 方便停在 ±0.1、±0.2；中间的倍数压窄，仍可拖过。
    private struct Scale {
        let stops: [Double]
        let anchors: [Double]
        let continuous: Bool
        let range: ClosedRange<Double>?
        var start: Double { anchors.first ?? 1 }

        init(_ limits: ConsoleZoom) {
            stops = limits.stops
            continuous = limits.fineRange != nil
            range = limits.fineRange
            if let range = limits.fineRange {
                anchors = Set(stops + [range.lowerBound, range.upperBound]).sorted()
            } else {
                anchors = stops
            }
        }

        func position(of factor: Double) -> Double {
            guard anchors.count > 1, factor > start else { return 0 }
            guard let upper = anchors.firstIndex(where: { $0 >= factor }) else { return 1 }
            let lower = anchors[upper - 1]
            let knots = Self.knots(span: anchors[upper] - lower, widen: continuous)
            let travel = Self.map(factor - lower, from: knots.offsets, to: knots.travel)
            return (Double(upper - 1) + travel) / Double(anchors.count - 1)
        }

        /// `snap` 是相对整条宽度的吸附半径，只在点按时传入。
        func factor(at position: Double, snap: Double = 0) -> Double {
            guard anchors.count > 1 else { return start }
            let unit = min(1, max(0, position))
            if !continuous {
                let index = Int((unit * Double(anchors.count - 1)).rounded())
                return anchors[min(anchors.count - 1, max(0, index))]
            }
            if snap > 0,
               let stop = stops.min(by: { abs(self.position(of: $0) - unit) < abs(self.position(of: $1) - unit) }),
               abs(self.position(of: stop) - unit) <= snap {
                return stop
            }
            let index = unit * Double(anchors.count - 1)
            let lower = min(Int(index), anchors.count - 2)
            let knots = Self.knots(span: anchors[lower + 1] - anchors[lower], widen: true)
            return tenth(anchors[lower] + Self.map(index - Double(lower), from: knots.travel, to: knots.offsets))
        }

        func adjusted(_ zoom: Double?, by offset: Double) -> Double {
            let position = position(of: zoom ?? start)
            if !continuous { return factor(at: position + offset / Double(max(1, anchors.count - 1))) }
            let current = factor(at: position)
            return tenth(current + offset * ConsoleZoomControls.tenth)
        }

        /// 一段相邻预设之内，倍数偏移和手指路程（0...1）的对应点。
        /// 两端各 0.25 占三分之一路程，±0.1、±0.2 才停得住；整段太短或是离散档位时保持线性。
        private static func knots(span: Double, widen: Bool) -> (offsets: [Double], travel: [Double]) {
            let near = 0.25
            guard widen, span > near * 3 else { return ([0, span], [0, 1]) }
            return ([0, near, span - near, span], [0, 1.0 / 3, 2.0 / 3, 1])
        }

        /// 按对应点分段线性换算，超出两端时取端点。
        private static func map(_ value: Double, from: [Double], to: [Double]) -> Double {
            guard let upper = from.firstIndex(where: { $0 >= value }) else { return to[to.count - 1] }
            guard upper > 0, from[upper] > from[upper - 1] else { return to[upper] }
            let fraction = (value - from[upper - 1]) / (from[upper] - from[upper - 1])
            return to[upper - 1] + (to[upper] - to[upper - 1]) * fraction
        }

        /// 连续落点取最近的 0.1，并夹在允许范围内。
        private func tenth(_ factor: Double) -> Double {
            let snapped = (factor * 10).rounded() / 10
            guard let range else { return snapped }
            let lower = (range.lowerBound * 10).rounded(.up) / 10
            let upper = (range.upperBound * 10).rounded(.down) / 10
            guard lower <= upper else { return min(range.upperBound, max(range.lowerBound, snapped)) }
            return min(upper, max(lower, snapped))
        }
    }
}
