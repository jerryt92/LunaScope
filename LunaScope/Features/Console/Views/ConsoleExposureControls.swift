import LunaTransportProtocol
import OpenCineCore
import SwiftUI

struct ConsoleExposureControls<CaptureControl: View>: View {
    let camera: CameraController
    @ViewBuilder let captureControl: () -> CaptureControl
    @State private var showsSheet = false

    var body: some View {
        if camera.shootingMode != .pano {
            Button {
                showsSheet = true
            } label: {
                Text(modeIcon)
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundStyle(modeIcon == "M" ? Palette.accent : .white)
                    .frame(maxWidth: .infinity, minHeight: ConsoleMenuLabel.minHeight)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!camera.canEditShootingSettings || (!hasAdjustableParameter && !camera.canSwitchExposureControlMode))
            .accessibilityLabel("console.settings.exposureControls")
            .accessibilityValue(modeIcon)
            .accessibilityIdentifier("console.exposure.controls")
            .sheet(isPresented: $showsSheet) {
                ExposureSheet(camera: camera, captureControl: captureControl)
            }
            .onChange(of: camera.shootingMode) { showsSheet = false }
            .onChange(of: camera.connected) { if !camera.connected { showsSheet = false } }
        }
    }

    private var modeIcon: String {
        switch camera.exposureControlMode {
        case .basic: "A"
        case .professional: "M"
        case nil: "—"
        }
    }

    private var hasAdjustableParameter: Bool {
        ExposureParameter.allCases.contains { $0.canAdjust(on: camera) }
    }
}

private enum ExposureParameter: String, CaseIterable, Identifiable {
    case shutter, iso, bias, whiteBalance, metering, focus

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .shutter: "console.settings.shutter"
        case .iso: "console.settings.iso"
        case .bias: "console.settings.exposureBias"
        case .whiteBalance: "console.settings.whiteBalance"
        case .metering: "console.settings.metering"
        case .focus: "console.settings.focus"
        }
    }

    var symbol: String {
        switch self {
        case .shutter: "camera.aperture"
        case .iso: "camera.filters"
        case .bias: "plusminus"
        case .whiteBalance: "thermometer.medium"
        case .metering: "viewfinder"
        case .focus: "scope"
        }
    }

    func canAdjust(on camera: CameraController) -> Bool {
        guard camera.canEditShootingSettings else { return false }
        switch self {
        case .shutter, .iso: return camera.canAdjustExposure
        case .bias: return camera.parameters?.exposureBiasTenths != nil
        case .whiteBalance: return camera.canSet(.whiteBalance)
        case .metering: return camera.parameters?.faceMetering != nil
        case .focus: return camera.parameters?.autofocus != nil && !camera.focusChoices.isEmpty
        }
    }
}

/// 专业页当前编辑的是固定曝光项，或 JSON 声明的画面项。
private enum SheetSelection: Hashable {
    case parameter(ExposureParameter)
    case image(String)
}

private struct ExposureSheet<CaptureControl: View>: View {
    let camera: CameraController
    let captureControl: () -> CaptureControl
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SheetSelection?

    private var active: SheetSelection {
        if camera.exposureControlMode != .professional { return .parameter(.bias) }
        return selection ?? .parameter(.bias)
    }

    /// 测光和对焦已在曝光项里，这里只追加 JSON 里的其余画面项。
    private var imageControls: [ConsoleCameraProfile.ImageControl] {
        camera.visibleImageControls().filter { $0.id != "focus" && $0.id != "metering" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    exposureModeSelector

                    parameterStrip
                    editor
                        .id(active)
                        .disabled(!canEditActive)
                        .opacity(canEditActive ? 1 : 0.55)
                        .background(Palette.preview, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)

                    HStack {
                        Button(action: resetParameter) {
                            Label("console.exposure.reset", systemImage: "arrow.counterclockwise")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                        .disabled(!canReset)
                        .opacity(canReset ? 1 : 0.4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        captureControl()
                            .frame(width: 90)

                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.panel)
            .navigationTitle("console.settings.exposureControls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.close") { dismiss() }
                }
            }
            .overlay { ConsoleNoticeOverlay(camera: camera) }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .presentationDetents([.height(370), .large])
        .presentationDragIndicator(.visible)
            .onChange(of: camera.parameters?.color) {
                if case .image(let id) = selection, camera.visibleImageControl(id: id) == nil {
                    selection = .parameter(.bias)
                }
            }
            .onAppear {
            if ExposureParameter.bias.canAdjust(on: camera) {
                selection = .parameter(.bias)
            } else if let parameter = ExposureParameter.allCases.first(where: { $0.canAdjust(on: camera) }) {
                selection = .parameter(parameter)
            }
        }
    }

    private var exposureModeSelector: some View {
        HStack(spacing: 4) {
            exposureModeButton("console.exposure.basic", mode: .basic)
            exposureModeButton("console.exposure.professional", mode: .professional)
        }
        .padding(4)
        .background(Palette.preview, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 280)
        .padding(.horizontal, 16)
        .disabled(!camera.canSwitchExposureControlMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("console.exposure.level"))
        .accessibilityIdentifier("console.exposure.level")
    }

    private func exposureModeButton(_ title: LocalizedStringKey, mode: LunaIQ3AMode) -> some View {
        let selected = camera.exposureControlMode == mode
        return Button {
            camera.setExposureControlMode(mode)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Palette.accent : .white)
                .background(selected ? Palette.field : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var parameterStrip: some View {
        if camera.exposureControlMode == .professional {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(ExposureParameter.allCases) { parameter in
                            parameterButton(parameter).id(SheetSelection.parameter(parameter))
                        }
                        ForEach(imageControls, id: \.id) { control in
                            imageButton(control).id(SheetSelection.image(control.id))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .onChange(of: active, initial: true) {
                    withAnimation(.snappy) { proxy.scrollTo(active) }
                }
            }
        } else {
            parameterLabel(.bias)
                .accessibilityElement(children: .combine)
        }
    }

    private func parameterButton(_ parameter: ExposureParameter) -> some View {
        Button { selection = .parameter(parameter) } label: {
            parameterLabel(parameter)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(parameter.title))
        .accessibilityValue(parameterValue(parameter))
        .accessibilityAddTraits(active == .parameter(parameter) ? .isSelected : [])
        .accessibilityIdentifier("console.exposure.parameter.\(parameter.rawValue)")
    }

    private func imageButton(_ control: ConsoleCameraProfile.ImageControl) -> some View {
        let value = camera.parameters?.imageValue(id: control.id)
        return Button { selection = .image(control.id) } label: {
            imageLabel(control, value: value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.title)
        .accessibilityValue(value.map(control.choiceLabel) ?? "—")
        .accessibilityAddTraits(active == .image(control.id) ? .isSelected : [])
        .accessibilityIdentifier("console.exposure.image.\(control.id)")
    }

    private func imageLabel(_ control: ConsoleCameraProfile.ImageControl, value: UInt64?) -> some View {
        let isSelected = active == .image(control.id)
        return VStack(spacing: 4) {
            Label(control.title, systemImage: control.symbol)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
            Text(value.map(control.choiceLabel) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? Palette.accent : Palette.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 68, minHeight: 48)
        .background(isSelected ? Palette.field : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Palette.accent.opacity(0.65) : .clear)
        }
    }

    private func parameterLabel(_ parameter: ExposureParameter) -> some View {
        let isSelected = active == .parameter(parameter)
        return VStack(spacing: 4) {
            Label(parameter.title, systemImage: parameter.symbol)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
            Text(parameterValue(parameter))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? Palette.accent : Palette.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 68, minHeight: 48)
        .background(isSelected ? Palette.field : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Palette.accent.opacity(0.65) : .clear)
        }
    }

    @ViewBuilder private var editor: some View {
        switch active {
        case .image(let id):
            if let control = camera.visibleImageControl(id: id) {
                let current = camera.parameters?.imageValue(id: control.id)
                optionButtons(camera.imageChoiceValues(for: control), current: current,
                              label: control.choiceLabel) { camera.setImageControl(control, value: $0) }
            }
        case .parameter(.bias):
            let values = ConsoleParameters.exposureBiasChoices
            ruler(values, current: camera.parameters?.exposureBiasTenths,
                  label: ConsoleParameters.exposureBiasLabel, apply: camera.setExposureBias)
        case .parameter(.shutter):
            ruler([nil] + camera.shutterChoices.map(Optional.some), current: Optional(shutter),
                  label: shutterLabel, apply: camera.setExposureShutter)
        case .parameter(.iso):
            let profile = camera.cameraProfile?.exposure
            let choices = [.auto] + (profile?.iso ?? []).map(ISOChoice.fixed) + (profile?.isoMax ?? []).map(ISOChoice.max)
            ruler(choices, current: camera.parameters?.exposure.map { ISOChoice($0) },
                  label: isoLabel, apply: applyISO)
        case .parameter(.whiteBalance):
            ruler([nil] + whiteBalanceChoices.map(Optional.some), current: whiteBalance,
                  label: whiteBalanceLabel) { kelvin in
                camera.set(.whiteBalance(kelvin.map { .kelvin($0) } ?? .auto))
            }
        case .parameter(.metering):
            optionButtons([false, true], current: camera.parameters?.faceMetering,
                          label: ConsoleParameters.meteringLabel, apply: camera.setMetering)
        case .parameter(.focus):
            optionButtons(camera.focusChoices, current: focus,
                          label: { $0.label }, apply: camera.setNativeFocus)
        }
    }

    private func ruler<Value: Hashable>(_ choices: [Value], current: Value?,
                                        label: (Value) -> String, apply: @escaping (Value) -> Void) -> some View {
        ExposureRuler(title: activeTitle, labels: choices.map(label),
                      selection: current.flatMap { choices.firstIndex(of: $0) },
                      currentLabel: activeValue) { index in
            guard choices.indices.contains(index) else { return }
            apply(choices[index])
        }
    }

    private func optionButtons<Value: Hashable>(_ choices: [Value], current: Value?,
                                                label: @escaping (Value) -> String,
                                                apply: @escaping (Value) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { options(choices, current: current, label: label, apply: apply) }
                .fixedSize(horizontal: true, vertical: false)
            VStack { options(choices, current: current, label: label, apply: apply) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 84)
    }

    private func options<Value: Hashable>(_ choices: [Value], current: Value?,
                                          label: @escaping (Value) -> String,
                                          apply: @escaping (Value) -> Void) -> some View {
        ForEach(choices, id: \.self) { choice in
            Button { apply(choice) } label: {
                Text(label(choice))
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .background(current == choice ? Palette.accent.opacity(0.18) : Palette.field,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(current == choice ? Palette.accent : .white)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(current == choice ? .isSelected : [])
        }
    }

    private var auto: String { String(localized: "console.settings.auto") }
    private var focus: LunaAFMode? { camera.currentFocusChoice }

    private var shutter: Double? {
        guard let seconds = camera.parameters?.exposure?.shutter else { return nil }
        return camera.shutterChoices.first { abs($0 - seconds) <= seconds * 0.005 } ?? seconds
    }

    /// 外层 nil 代表相机尚未回报；内层 nil 是自动白平衡。
    private var whiteBalance: Int?? {
        switch camera.value(.whiteBalance) {
        case .whiteBalance(.auto): .some(nil)
        case .whiteBalance(.kelvin(let kelvin)): .some(kelvin)
        default: nil
        }
    }

    private var whiteBalanceChoices: [Int] {
        guard let balance = camera.cameraProfile?.whiteBalance else { return [] }
        let choices = balance.choices
        guard let current = whiteBalance.flatMap({ $0 }), let kelvin = UInt64(exactly: current),
              balance.allows(kelvin), !choices.contains(current) else { return choices }
        return (choices + [current]).sorted()
    }

    private func parameterValue(_ parameter: ExposureParameter) -> String {
        switch parameter {
        case .shutter: return camera.parameters?.exposure == nil ? "—" : shutterLabel(shutter)
        case .iso: return camera.parameters?.exposure.map { isoLabel(ISOChoice($0)) } ?? "—"
        case .bias: return camera.parameters?.exposureBiasTenths.map(ConsoleParameters.exposureBiasLabel) ?? "—"
        case .whiteBalance: return whiteBalance.map(whiteBalanceLabel) ?? "—"
        case .metering: return camera.parameters?.faceMetering.map(ConsoleParameters.meteringLabel) ?? "—"
        case .focus: return focus?.label ?? "—"
        }
    }

    private func shutterLabel(_ value: Double?) -> String { value.map(ConsoleManualExposure.shutterLabel) ?? auto }
    private func whiteBalanceLabel(_ value: Int?) -> String { value.map { "\($0) K" } ?? auto }

    private func isoLabel(_ choice: ISOChoice) -> String {
        switch choice {
        case .auto: auto
        case .fixed(let value): value.formatted(.number.grouping(.never))
        case .max(let value): ConsoleManualExposure.isoMaxLabel(value)
        }
    }

    private func applyISO(_ choice: ISOChoice) {
        switch choice {
        case .auto: camera.setExposureISO(nil)
        case .fixed(let value): camera.setExposureISO(value)
        case .max(let value): camera.setExposureISOMax(value)
        }
    }

    private var activeTitle: LocalizedStringKey {
        switch active {
        case .parameter(let parameter): parameter.title
        case .image(let id): LocalizedStringKey(camera.visibleImageControl(id: id)?.title ?? "")
        }
    }

    private var activeValue: String {
        switch active {
        case .parameter(let parameter): return parameterValue(parameter)
        case .image(let id):
            guard let control = camera.visibleImageControl(id: id) else { return "—" }
            return camera.parameters?.imageValue(id: id).map(control.choiceLabel) ?? "—"
        }
    }

    private var canEditActive: Bool {
        switch active {
        case .parameter(let parameter): parameter.canAdjust(on: camera)
        case .image(let id):
            camera.canEditShootingSettings && camera.parameters?.imageValue(id: id) != nil
                && camera.visibleImageControl(id: id) != nil
        }
    }

    /// 当前项是否偏离可恢复的默认值。画面项的默认值来自机型 JSON。
    private var canReset: Bool {
        switch active {
        case .parameter(let parameter):
            guard parameter.canAdjust(on: camera) else { return false }
            switch parameter {
            case .bias: return camera.parameters?.exposureBiasTenths != 0
            case .shutter: return shutter != nil
            case .iso: return ISOChoice(camera.parameters?.exposure) != .auto
            case .whiteBalance: return whiteBalance.flatMap { $0 } != nil
            case .metering:
                guard let control = camera.visibleImageControl(id: "metering"),
                      let current = camera.parameters?.faceMetering else { return false }
                return (current ? 1 : 0) != control.defaultValue
            case .focus:
                guard let control = camera.visibleImageControl(id: "focus"),
                      let current = camera.parameters?.autofocus else { return false }
                return current != control.defaultValue
            }
        case .image(let id):
            guard let control = camera.visibleImageControl(id: id),
                  let current = camera.parameters?.imageValue(id: id) else { return false }
            let choices = camera.imageChoiceValues(for: control)
            let restore = choices.contains(control.defaultValue) ? control.defaultValue : nil
            return restore != nil && current != restore
        }
    }

    private func resetParameter() {
        switch active {
        case .parameter(.bias): camera.setExposureBias(0)
        case .parameter(.shutter): camera.setExposureShutter(nil)
        case .parameter(.iso): applyISO(.auto)
        case .parameter(.whiteBalance): camera.set(.whiteBalance(.auto))
        case .parameter(.focus):
            if let control = camera.visibleImageControl(id: "focus") {
                camera.restoreImageControl(control)
            }
        case .parameter(.metering):
            if let control = camera.visibleImageControl(id: "metering") {
                camera.restoreImageControl(control)
            }
        case .image(let id):
            if let control = camera.visibleImageControl(id: id) {
                camera.restoreImageControl(control)
            }
        }
    }
}

/// 原生横向吸附滚动，松手停稳后只提交居中的档位。程序滚动和相机回读只更新刻度位置。
private struct ExposureRuler: View {
    let title: LocalizedStringKey
    let labels: [String]
    let selection: Int?
    let currentLabel: String
    let apply: (Int) -> Void
    @State private var center: Int?
    @State private var scrollingByTouch = false
    @ScaledMetric(relativeTo: .footnote) private var cellWidth: CGFloat = 74
    @ScaledMetric(relativeTo: .footnote) private var rulerHeight: CGFloat = 84

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(labels.indices, id: \.self) { index in
                        Button { choose(index) } label: {
                            VStack(spacing: 6) {
                                Text(labels[index])
                                    .font(.footnote.weight(index == center ? .bold : .regular).monospacedDigit())
                                    .foregroundStyle(index == center ? .white : Palette.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                tick(highlighted: index == center && (selection != nil || scrollingByTouch))
                            }
                            .frame(width: cellWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, max(0, (geometry.size.width - cellWidth) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned(anchor: .center))
            .scrollPosition(id: $center, anchor: .center)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollingByTouch = true }
                if phase == .idle, scrollingByTouch {
                    scrollingByTouch = false
                    if let center, selection != center { apply(center) }
                }
            }
        }
        .frame(height: rulerHeight)
        .onChange(of: selection, initial: true) {
            if !scrollingByTouch { center = selection ?? labels.indices.first }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(currentLabel)
        .accessibilityAdjustableAction { direction in
            let index = selection ?? center ?? 0
            switch direction {
            case .increment:
                if labels.indices.contains(index + 1) { choose(index + 1) }
            case .decrement:
                if labels.indices.contains(index - 1) { choose(index - 1) }
            @unknown default: break
            }
        }
    }

    private func tick(highlighted: Bool) -> some View {
        HStack(spacing: 0) {
            minorTick
            Capsule()
                .fill(highlighted ? Palette.accent : Palette.secondary)
                .frame(width: highlighted ? 3 : 1, height: 22)
                .frame(maxWidth: .infinity)
            minorTick
        }
    }

    private var minorTick: some View {
        Capsule()
            .fill(Palette.secondary.opacity(0.45))
            .frame(width: 1, height: 10)
            .frame(maxWidth: .infinity)
    }

    private func choose(_ index: Int) {
        withAnimation(.snappy(duration: 0.23)) { center = index }
        if selection != index { apply(index) }
    }
}

/// ISO 选项：自动、上限或固定值。
enum ISOChoice: Hashable {
    case auto
    case max(UInt64)
    case fixed(UInt64)

    init(_ exposure: ConsoleExposure?) {
        if let limit = exposure?.isoTopLimit { self = .max(limit) }
        else if let iso = exposure?.iso { self = .fixed(iso) }
        else { self = .auto }
    }
}

struct ConsoleManualExposure {
    let camera: CameraController

    var values: [String] {
        guard camera.exposureControlMode != .basic else { return [] }
        var result: [String] = []
        if let limit = camera.parameters?.exposure?.isoTopLimit {
            result.append("ISO \(Self.isoMaxLabel(limit))")
        } else if let iso = camera.parameters?.exposure?.iso {
            result.append("ISO \(iso)")
        }
        if let shutter = camera.parameters?.exposure?.shutter {
            result.append(Self.shutterLabel(shutter))
        }
        if case .whiteBalance(.kelvin(let kelvin)) = camera.value(.whiteBalance) {
            result.append("\(kelvin) K")
        }
        return result
    }

    nonisolated static func isoMaxLabel(_ value: UInt64) -> String {
        String(localized: "console.settings.isoMax \(value)")
    }

    nonisolated static func shutterLabel(_ seconds: Double) -> String {
        let denominator = 1 / seconds
        if seconds < 1, abs(denominator.rounded() - denominator) < 0.01 {
            return "1/\(Int(denominator.rounded()))"
        }
        let value = seconds.formatted(.number.precision(.fractionLength(0...4)))
        return String(localized: "console.settings.seconds \(value)")
    }
}
