import LunaTransportProtocol
import SwiftUI

/// 参数预设列表：点击套用、拖动排序、重命名、左侧删除。保存与套用仍走控制台的相机操作队列。
struct ConsolePresetView: View {
    let camera: CameraController
    @State private var naming = false
    @State private var renaming: ConsoleMemory.Preset?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("console.presets.save", systemImage: "plus") {
                        name = ""
                        naming = true
                    }
                    .disabled(!camera.canSavePreset)
                    .accessibilityIdentifier("console.presets.save")
                } footer: {
                    Text("console.presets.detail")
                }
                Section {
                    if camera.memory.presets.isEmpty {
                        ContentUnavailableView("console.presets.empty", systemImage: "slider.horizontal.3")
                    } else {
                        ForEach(camera.memory.presets) { preset in
                            presetRow(preset)
                        }
                        .onMove(perform: camera.movePresets)
                        .onDelete(perform: deletePresets)
                    }
                }
                .environment(\.editMode, .constant(camera.memory.presets.isEmpty ? .inactive : .active))
            }
            .navigationTitle("console.presets.title")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                // 记忆页也用同一套穿透式轻提示，避免再走列表内联文案。
                ConsoleNoticeOverlay(camera: camera)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("common.close")
                        .accessibilityIdentifier("drawer.close")
                }
            }
            .alert("console.presets.nameTitle", isPresented: $naming) {
                TextField("console.presets.name", text: $name)
                Button("common.cancel", role: .cancel) {}
                Button("console.presets.save") { camera.savePreset(name: name) }
            }
            .alert("console.presets.renameTitle", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("console.presets.name", text: $name)
                Button("common.cancel", role: .cancel) { renaming = nil }
                Button("console.presets.rename") {
                    if let id = renaming?.id {
                        camera.renamePreset(id, name: name)
                    }
                    renaming = nil
                }
            }
        }
        .presentationDetents([.large])
    }

    private func presetRow(_ preset: ConsoleMemory.Preset) -> some View {
        let canApply = camera.canEditShootingSettings && camera.supportedParameters(in: preset) != nil
        // 重命名只走长按菜单，不再放右侧铅笔按钮。
        return row(preset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canApply else { return }
                // 先关界面，再让控制台按 restore 顺序下发，避免 sheet 内操作抢总线。
                dismiss()
                camera.applyPreset(preset)
            }
            .opacity(canApply ? 1 : 0.45)
            .accessibilityIdentifier("console.presets.row")
            .accessibilityAddTraits(canApply ? .isButton : [])
            .contextMenu {
                Button("console.presets.rename", systemImage: "pencil") {
                    name = preset.name
                    renaming = preset
                }
            }
    }

    /// 批量删除选中的预设。
    private func deletePresets(at offsets: IndexSet) {
        offsets.map { camera.memory.presets[$0].id }.forEach(camera.deletePreset)
    }

    private func row(_ preset: ConsoleMemory.Preset) -> some View {
        VStack(alignment: .leading, spacing: ConsoleMenuLabel.spacing) {
            if preset.name.isEmpty {
                Text(preset.savedAt, format: .dateTime.year().month().day().hour().minute())
            } else {
                Text(preset.name)
            }
            Text(summary(preset))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ preset: ConsoleMemory.Preset) -> String {
        let profile = ConsoleCameraProfile.bundled.first { $0.id == preset.profileID } ?? camera.cameraProfile
        return preset.parameters.detailSummary(profile: profile)
    }
}

#Preview { ConsolePresetView(camera: CameraController()) }
