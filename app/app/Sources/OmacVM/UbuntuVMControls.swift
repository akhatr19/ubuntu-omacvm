import AppKit
import SwiftUI

/// Reuse the existing settings rows with state scoped to the selected machine.
/// Feature provisioning is owned by the launcher's existing build lifecycle.
struct UbuntuVMControls: View {
    let config: VMConfig
    let running: Bool
    enum Pane { case resources, input, network }
    let pane: Pane
    let helperBusy: Bool
    var update: ([String]) -> Void
    var changed: () -> Void = {}
    var storage: StorageModel?
    var openVM: () -> Void
    var deleteVM: (VMConfig) -> Void
    @StateObject private var model: AppState
    @StateObject private var mouse = MagicMouseWatch()

    init(config: VMConfig, running: Bool, pane: Pane, helperBusy: Bool = false, update: @escaping ([String]) -> Void = { _ in }, changed: @escaping () -> Void = {}, storage: StorageModel? = nil, openVM: @escaping () -> Void = {}, deleteVM: @escaping (VMConfig) -> Void = { _ in }) {
        self.config = config; self.running = running; self.pane = pane; self.helperBusy = helperBusy; self.update = update; self.changed = changed; self.storage = storage; self.openVM = openVM; self.deleteVM = deleteVM
        _model = StateObject(wrappedValue: Self.makeModel(config, running: running))
    }
    private static func makeModel(_ config: VMConfig, running: Bool) -> AppState {
        let model = AppState(watchDrives: false)
        model.config = config; model.screen = .ready; model.vmRunning = { running }
        return model
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = model.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            if pane != .network {
                Text(pane == .input ? "Desktop input preferences apply app-wide; gesture enablement belongs to this VM." : "CPU, memory, graphics and disk belong to this VM. Other desktop preferences apply app-wide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if config.isCustom {
                Card { ResourcesRow(state: model) }
                Text("Basic virtio display and audio output. Advanced graphics, guest disk resizing and desktop integration are unavailable until a supported Linux profile is enabled.")
                    .foregroundStyle(.secondary)
                if let storage { Card { StorageRows(storage: storage, selected: config.folder, open: openVM, delete: deleteVM) } }
            } else if pane == .network {
                Card { FastNetworkRow(state: model) }
            } else if pane == .input {
                Text("Return to macOS: Control + Option + Escape (⌃⌥ Esc)").font(.headline)
                Card {
                    KeyboardRow(state: model)
                    NativePointerRow(tick: model.tick)
                    EscapeRow(tick: model.tick)
                    ShareKeyboardRow(tick: model.tick)
                    if mouse.connected { MagicMouseRow(tick: model.tick, gesturesOff: VMRecord.isOff("gestures", folder: config.folder)) }
                    if config.isUbuntu {
                        UbuntuFeatureRow(state: model, feature: "gestures", title: "Trackpad gestures", detail: "Configure fullscreen or focused-window capture and check the installed helper.", onUpdate: update, helperBusy: helperBusy)
                        UbuntuFeatureRow(state: model, feature: "drag-drop", title: "Finder drops", detail: "Copy dropped files into Downloads without overwriting existing files.", onUpdate: update, helperBusy: helperBusy)
                    } else if config.isOmarchy {
                        MacIMERow(state: model)
                        SwipeOutRow(tick: model.tick, gesturesOff: VMRecord.isOff("gestures", folder: config.folder))
                        MissionControlRow(state: model, gesturesOff: VMRecord.isOff("gestures", folder: config.folder))
                    }
                }
            } else {
                Text("CPU, memory & graphics").font(.headline)
                Card {
                    ResourcesRow(state: model)
                    if !config.isCustom { GraphicsRow(state: model) }
                    GPUOffMainLoopRow(tick: model.tick)
                    VKWindowsNoCopyRow(tick: model.tick)
                }
                Text("Display & sound").font(.headline)
                Card {
                    StartInRow(state: model)
                    KeepDockAwayRow(tick: model.tick)
                    PresentTilesRow(tick: model.tick)
                    if Mac.hasExtraBrightnessDisplay { ExtraBrightnessRow(tick: model.tick) }
                    SoundThreadRow(tick: model.tick)
                    MediaControlsRow(tick: model.tick)
                    CloseActionRow(tick: model.tick)
                }
                Text("Storage & USB devices").font(.headline)
                Card { DiskRow(state: model); USBRow(state: model) }
                if let storage {
                    Text("VM folders & maintenance").font(.headline)
                    Card { StorageRows(storage: storage, selected: config.folder, open: openVM, delete: deleteVM) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reloadSettings() }
        .onChange(of: config) { _, value in if model.config != value { model.config = value } }
        .onChange(of: model.config) { _, _ in changed() }
        .onChange(of: running) { _, value in model.vmRunning = { value } }
        .onAppear { model.reloadSettings(); if pane == .resources { storage?.refresh() } }
    }
}
