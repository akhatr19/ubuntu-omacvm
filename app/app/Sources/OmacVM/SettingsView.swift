import AppKit
import OmacVMDesktop
import OmacVMFeatures
import OmacVMWindow
import SwiftUI

/// The VM window before Start (docs/design/settings-3.1): the header with
/// the VM and Start, the update banner, and the VM's settings in five
/// sections with the sidebar. Every row reads and writes the same setting as
/// before 3.1 (AGENTS.md, "Settings"), so an update keeps every choice; what
/// `omacvm` or the control centre changed shows when the window comes back
/// to the front.
struct ReadyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared
    /// The window pictures (--render-vm-window): this keyboard note and this
    /// "omacvm in Terminal" state instead of the Mac's, and more.
    var preview: RenderVMWindow.Preview? = nil
    @State private var sheet: ReadySheet?
    /// The VM to delete runs (or omacvm works on it): asked once, when the sheet opens.
    @State private var deleteBusy = false
    @State private var managedRunning = true
    @State private var gesturesPermissions = false

    enum ReadySheet: Identifiable {
        case delete(VMConfig), whatsNew
        var id: String {
            switch self {
            case .delete(let c): return "delete-" + c.folder.path
            case .whatsNew: return "whats-new"
            }
        }
    }

    private var managed: Bool { Product.isUbuntu && DeveloperActions.name(state.config) != nil }
    private var running: Bool { preview?.running ?? (managed ? managedRunning : state.vmRunning()) }
    /// A move to Omarchy 4.5 that is not over: Start and Update VM wait for Resume or Undo.
    private var moveOpen: Bool {
        if let m = preview?.move {
            switch m.card {
            case .failed, .interrupted, .running, .stopping, .undoing: return true
            default: return false
            }
        }
        _ = state.tick
        return MoveFiles.journal(state.config)?.open == true
    }
    /// Is this Mac set up for the VM (MacSetup): the window pictures' own.
    private var macSetup: MacSetup? { preview?.macSetup ?? state.macSetup }

    var body: some View {
        WindowShell(nav: SettingsNav.items) {
            header
        } notices: {
            UpdateBanner(updater: updater, running: running) { sheet = .whatsNew }
            // One blue banner at a time: the app's update first, the move's offer quiet meanwhile.
            if !Product.isUbuntu {
                OmarchyMoveCard(state: state, running: running, preview: preview?.move, quiet: UpdateBanner.shows(updater))
            }
            notices
        } content: {
            SettingsSections(state: state, preview: preview, running: running) { vm in
                deleteBusy = preview?.running ?? !Storage.busyFolders([vm.folder]).isEmpty
                sheet = .delete(vm)
            }
        }
        .environment(\.spyStart, preview?.section)
        .sheet(item: $sheet) { s in
            switch s {
            case .delete(let vm):
                DeleteSheet(vm: vm, size: state.storage.vms.first { $0.folder.path == vm.folder.path }?.size,
                            running: deleteBusy) { delete in
                    sheet = nil
                    if delete { state.storage.trash(vm) }
                }
            case .whatsNew:
                WhatsNewSheet(updater: updater, running: running) { sheet = nil }
            }
        }
        .sheet(isPresented: $gesturesPermissions) { UbuntuGesturesPermissions() }
        .onAppear { if let s = preview?.sheet { sheet = s } }
        // `omacvm`, the control centre or another window may have changed a
        // setting meanwhile: read them again (every row follows state.tick).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.reloadSettings()
            // Back from System Settings, or a helper installed meanwhile.
            if preview == nil { state.refreshMacSetup() }
        }
        .onAppear { if preview == nil { state.refreshMacSetup() } }
        .onChange(of: state.config.folder) { _, _ in if preview == nil { state.refreshMacSetup() } }
        .task(id: state.config.folder) {
            while !Task.isCancelled && preview == nil {
                if managed {
                    let folder = state.config.folder
                    let busy = await Task.detached { !Storage.busyFolders([folder]).isEmpty }.value
                    if Task.isCancelled { return }
                    managedRunning = busy
                }
                try? await Task.sleep(for: .seconds(3))
                // Only while the window shows (not while a VM runs and it is put away).
                if NSApp.windows.contains(where: { $0.isVisible && $0.contentViewController is NSHostingController<RootView> }) {
                    state.reloadSettings()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        WindowHeader(title: state.config.name,
                     pill: running ? StatusPill(text: "Running", dot: Look.green) : StatusPill(text: "Stopped"),
                     facts: "\(state.config.cpus) CPUs · \(state.config.memoryMB / 1024) GB memory · \(state.config.diskGB) GB disk"
                         + (state.config.user.isEmpty ? "" : " · user \(state.config.user)"),
                     factsInfo: factsInfo) {
            AppIconButton()
        } trailing: {
            let app = preview?.appVersion ?? OmacVMVersion.app
            let behind = app.map { OmacVMVersion.vmIsBehind(state.config.guestVersion, app: $0) } ?? false
            // Also when this Mac's helpers are not set up for the VM (a VM
            // copied at the same version had no Update VM anywhere).
            if !managed && (Product.isUbuntu || behind || macSetup?.wantsUpdateVM == true) {
                Button {
                    state.updateVM()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Look.orange).frame(width: 6, height: 6)
                        Text("Update VM")
                    }
                }
                .help(Product.isUbuntu
                      ? "Start Ubuntu without a window, update its guest integrations from this app, and shut it down. Your files and Ubuntu settings stay."
                      : behind
                      ? "OmacVM in this VM is \(state.config.guestVersion.map { "\($0)" } ?? "from an older app"); this app has \(app ?? ""). Update VM starts the VM without a window, updates OmacVM in it and its helpers on the Mac (a few minutes) and shuts it down. Your files and settings in \(Product.guestName) stay."
                      : "\(macSetup?.title(vm: state.config.name) ?? ""). Update VM starts the VM without a window, sets up its helpers on this Mac and gives the VM this Mac's token (a few minutes), then shuts it down. Your files and settings in \(Product.guestName) stay.")
                .disabled(state.storage.moving != nil || state.config.filesProblem != nil || running || moveOpen)
                .layoutProbe("update-vm")
            }
            Button(managed ? (running ? "Open Desktop…" : "Start Desktop") : (running ? "Show" : "Start")) {
                if managed {
                    if UbuntuNetworking.showDesktop(state.config) { return }
                    if running {
                        let alert = NSAlert()
                        alert.messageText = "Restart \(state.config.name) to open its desktop?"
                        alert.informativeText = "This stops running Linux commands and servers. Save your work first."
                        alert.addButton(withTitle: "Restart for Desktop")
                        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    state.startVM()
                } else if running { state.showVM() } else { state.startVM() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!running && (state.storage.moving != nil || state.config.filesProblem != nil || moveOpen))
            .help(moveOpen ? MoveFiles.openWhy(state.config) ?? "" : "")
            .layoutProbe("start")
        }
    }

    /// The VM's memory and its graphics memory side by side: the VM's RAM is
    /// fixed, its graphics come from the Mac on top, as needed (GPUMemory).
    private var factsInfo: String {
        "Set when the VM was made. CPUs and memory change under General, the disk under Storage. "
            + "\(GPUMemory.lastRun(GPUMemory.read(for: state.config)))\n\n\(GPUMemory.explanation)"
    }

    // MARK: Notices under the header

    @ViewBuilder private var notices: some View {
        // While an update waits for the VM, the banner says so already.
        if let n = updater.notice, !(updater.staged != nil && updater.installWhenIdle) {
            MessageStrip(text: n) { updater.notice = nil }
        }
        if let m = state.message {
            MessageStrip(text: m, error: !state.messageIsInfo) { state.message = nil }
        }
        if let p = state.config.filesProblem {
            MessageStrip(text: p, error: true)
        }
        // This Mac is not set up for the VM (a folder copied from another
        // Mac, a helper not allowed): said here as long as it is so, with
        // what fixes it. Later in the question before a start does not hide it.
        if let s = macSetup, s.needsAction, state.config.filesProblem == nil {
            NoticeStrip(text: MacSetup.displayName(s.notice(vm: state.config.name)), info: MacSetup.displayName(s.info(vm: state.config.name)), action: s.button,
                        disabled: s.fix == .updateVM && (running || state.storage.moving != nil)) {
                if Product.isUbuntu && s.fix == .settings && s.helpers.contains("OmacVM Gestures") {
                    gesturesPermissions = true
                } else { state.fixMacSetup(s) }
            }
        }
    }
}

extension EnvironmentValues {
    /// The window pictures: the section the settings start scrolled to.
    @Entry var spyStart: String? = nil
}

/// The six sections: General, Display, Input, Output (the sound), Sharing & Devices,
/// Storage & Updates.
struct SettingsSections: View {
    @ObservedObject var state: AppState
    var preview: RenderVMWindow.Preview?
    var running: Bool
    var delete: (VMConfig) -> Void
    @StateObject private var mouse = MagicMouseWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "General", first: true)
            Card {
                ResourcesRow(state: state)
                GraphicsRow(state: state)
                if Product.isUbuntu {
                    SettingRow(title: "WebGPU and OpenCL", subtitle: "Use the WebGPU browser for compute and the Video browser for hardware decoding. Requires Vulkan graphics.", probe: "ubuntu-compute")
                } else {
                    GPUComputeRow(state: state)
                }
                GPUOffMainLoopRow(tick: state.tick)
                VKWindowsNoCopyRow(tick: state.tick)
                if !Product.isUbuntu { GhosttyGPURow(tick: state.tick, folder: state.config.folder, running: running) }
                CloseActionRow(tick: state.tick)
            }
        }
        .spySection("general")
        if Product.isUbuntu {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "Developer & SSH")
                Card { DeveloperRow(state: state) }
            }.spySection("developer")
        }
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Display")
            Card {
                StartInRow(state: state, previewNotch: preview?.notch, previewMenuBar: preview?.menuBar)
                if !Product.isUbuntu && (preview?.notch ?? Mac.hasNotch) {
                    NotchSkipRow(state: state, previewInfo: preview?.notchSkipInfo ?? false)
                }
                KeepDockAwayRow(tick: state.tick)
                if !Product.isUbuntu && (preview?.hdr ?? Mac.hasHDRDisplay) {
                    HDRRow(tick: state.tick, folder: state.config.folder, running: running)
                }
                if preview?.extraBrightness ?? Mac.hasExtraBrightnessDisplay {
                    ExtraBrightnessRow(tick: state.tick)
                }
                if !Product.isUbuntu { PauseWhileHiddenRow(tick: state.tick) }
                if Product.isUbuntu {
                    NativePointerRow(tick: state.tick)
                } else {
                    PointerPlaneRow(tick: state.tick)
                }
                PresentTilesRow(tick: state.tick)
                EscapeRow(tick: state.tick)
                if preview?.magicMouse ?? mouse.connected {
                    MagicMouseRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
                }
            }
        }
        .spySection("display")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Input")
            Card {
                KeyboardRow(state: state, preview: preview?.keyNote)
                if Product.isUbuntu {
                    SettingRow(title: "Input methods", subtitle: "Configure languages and input sources in Ubuntu Settings → Keyboard.", probe: "ubuntu-input")
                    UbuntuFeatureRow(state: state, feature: "gestures", title: "Trackpad gestures",
                                     detail: "Three-finger swipes in full screen use GNOME workspaces and Overview. Installs the Mac gestures helper; macOS will ask for Accessibility and Input Monitoring.")
                } else {
                    MacIMERow(state: state)
                }
                if !Product.isUbuntu {
                    SwipeOutRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
                }
                ShareKeyboardRow(tick: state.tick)
            }
        }
        .spySection("input")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Output")
            Card {
                SoundThreadRow(tick: state.tick)
                MediaControlsRow(tick: state.tick)
            }
        }
        .spySection("output")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Sharing & Devices")
            Card {
                MacFolderRow(state: state)
                if Product.isUbuntu {
                    UbuntuFeatureRow(state: state, feature: "drag-drop", title: "Finder drops",
                                     detail: "Drop files onto the VM window to copy them into Ubuntu's Downloads folder. Existing files are kept.")
                } else { DragDropRow(state: state) }
                USBRow(state: state)
                if DeveloperActions.name(state.config) == nil { FastNetworkRow(state: state) }
            }
        }
        .spySection("sharing")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Storage & Updates")
            Card {
                DiskRow(state: state, preview: preview?.disk)
                StorageRows(storage: state.storage, selected: state.config.location == nil ? nil : state.config.folder,
                            open: { state.openExisting() }, delete: delete)
                if !Product.isUbuntu { MoveBackupRow(state: state, running: running, preview: preview?.moveBackup) }
                if !Product.isUbuntu { CommandLineRow(preview: preview?.terminal) }
                if Product.isUbuntu {
                    SettingRow(title: "App updates", subtitle: "UbuntuVM updates are installed from this project's releases.", probe: "ubuntu-updates") {
                        Link("UbuntuVM source", destination: URL(string: "https://github.com/akhatr19/ubuntu-omacvm")!)
                    }
                } else {
                    UpdateRow(updater: Updater.shared, running: running)
                }
            }
            ForEach(state.storage.disconnected, id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(Look.red).padding(.top, 8).padding(.horizontal, 4)
            }
            if let n = state.storage.note {
                Text(n).font(.subheadline).foregroundStyle(state.storage.noteIsError ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 8).padding(.horizontal, 4)
            }
            Button("Delete VM…") { delete(state.config) }
                .buttonStyle(.plain)
                .foregroundStyle(Look.red)
                .disabled(state.storage.moving != nil || (preview == nil && MoveFiles.journal(state.config)?.state == .running))
                .padding(.top, 14)
                .padding(.leading, 4)
                .layoutProbe("delete")
        }
        .spySection("storage")
    }
}
