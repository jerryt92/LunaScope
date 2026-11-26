import AVFoundation
import LunaTransportApple
import LunaTransportProtocol
import SwiftUI

/// Hit testing and camera coordinates both use the displayed video rectangle, excluding the bars.
struct ConsolePreviewGestures: View {
    let camera: CameraController
    @State private var focus: FocusMark?
    @GestureState private var selection: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let raster = camera.previewSize
            if raster.width > 0, raster.height > 0, geometry.size.width > 0, geometry.size.height > 0 {
                let frame = AVMakeRect(aspectRatio: raster, insideRect: CGRect(origin: .zero, size: geometry.size))
                interaction(in: frame.size)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .onChange(of: camera.shootingMode) { focus = nil }
        .onChange(of: camera.previewSize) { focus = nil }
        .task(id: focus?.id) {
            guard let id = focus?.id else { return }
            do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
            if focus?.id == id { focus = nil }
        }
    }

    private func interaction(in size: CGSize) -> some View {
        let taps = SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture())
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(taps.onEnded { value in
                    switch value {
                    case .first(let tap):
                        if camera.canTrackSubject {
                            track(at: tap.location, in: size)
                        } else {
                            focus(at: tap.location, in: size)
                        }
                    case .second(let tap):
                        focus(at: tap.location, in: size)
                    }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .updating($selection) { drag, selection, _ in
                        guard camera.canTrackSubject else { return }
                        selection = rectangle(from: drag.startLocation, to: drag.location, in: size)
                    }
                    .onEnded { drag in
                        guard camera.canTrackSubject else { return }
                        let box = rectangle(from: drag.startLocation, to: drag.location, in: size)
                        guard box.width >= 16, box.height >= 16 else { return }
                        camera.trackPreview(normalized(box, in: size))
                    })
                .accessibilityLabel("console.preview.title")
                .accessibilityAction(named: Text("console.preview.focusCenter")) {
                    focus(at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
                }

            if let box = camera.tracking.subjectBox ?? camera.tracking.searchBox {
                let frame = CGRect(x: box.x * size.width, y: box.y * size.height,
                                   width: box.width * size.width, height: box.height * size.height)
                trackingFrame(frame, tint: camera.tracking.tracking ? .green : Palette.accent)
            }
            if let selection { outline(selection, tint: Palette.accent) }
            if let focus {
                let side = min(size.width, size.height) * 0.14
                outline(CGRect(x: focus.point.x * size.width - side / 2,
                               y: focus.point.y * size.height - side / 2,
                               width: side, height: side), tint: Palette.accent)
            }
        }
        .clipped()
    }

    /// 取消叉放在框外右上角，颜色与框一致，无圆形底。
    private func trackingFrame(_ frame: CGRect, tint: Color) -> some View {
        let width = max(0, frame.width)
        let height = max(0, frame.height)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint, lineWidth: 2)
                .frame(width: width, height: height)
                .allowsHitTesting(false)
            if camera.canUsePreviewGestures {
                Button(action: camera.cancelPreviewTracking) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 框外右上，留一点缝但不离太远。
                .offset(x: 20, y: -20)
                .accessibilityLabel("console.preview.cancelTracking")
                .accessibilityIdentifier("console.preview.cancelTracking")
            }
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .position(x: frame.midX, y: frame.midY)
    }

    private func outline(_ frame: CGRect, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(tint, lineWidth: 2)
            .frame(width: max(0, frame.width), height: max(0, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func focus(at location: CGPoint, in size: CGSize) {
        let point = CGPoint(x: location.x / size.width, y: location.y / size.height)
        guard camera.focusPreview(at: point, aspect: Double(size.width / size.height)) else { return }
        focus = FocusMark(point: point)
    }

    private func track(at location: CGPoint, in size: CGSize) {
        let side = min(size.width, size.height) * 0.24
        let left = min(max(0, location.x - side / 2), size.width - side)
        let top = min(max(0, location.y - side / 2), size.height - side)
        camera.trackPreview(normalized(CGRect(x: left, y: top, width: side, height: side), in: size))
    }

    private func rectangle(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        let end = CGPoint(x: min(max(0, end.x), size.width), y: min(max(0, end.y), size.height))
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    private func normalized(_ box: CGRect, in size: CGSize) -> LunaSubjectTracking.Box {
        .init(x: Double(box.minX / size.width), y: Double(box.minY / size.height),
              width: Double(box.width / size.width), height: Double(box.height / size.height))
    }

    private struct FocusMark {
        let id = UUID()
        let point: CGPoint
    }
}
