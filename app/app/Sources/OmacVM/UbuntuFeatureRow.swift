import AppKit
import SwiftUI

/// Ubuntu features use its own installer; enabling gestures explicitly installs its Mac helper.
struct UbuntuFeatureRow: View {
    @ObservedObject var state: AppState
    let feature: String
    let title: String
    let detail: String
    var onUpdate: (([String]) -> Void)? = nil
    var helperBusy = false
    @State private var busy = false
    @State private var error: String?
    @State private var permissions = false

    private var on: Bool { !VMRecord.isOff(feature, folder: state.config.folder) }

    var body: some View {
        SettingRow(title: title, subtitle: error ?? detail, subtitleIsError: error != nil, probe: "ubuntu-\(feature)") {
            if busy { ProgressView().controlSize(.small) }
            Button(on ? "Disable" : feature == "gestures" ? "Install Helper and Enable…" : "Enable") { change() }
                .disabled(busy || state.vmRunning() || helperBusy)
        }
        if feature == "gestures" {
            SettingRow(title: "Gestures helper", subtitle: "Return to macOS: Control + Option + Escape (⌃⌥ Esc).", probe: "ubuntu-gesture-permissions") {
                Button("Gestures & Permissions…") { permissions = true }
                Button("Install/Update Helper…") { installGestures() }.disabled(busy || state.vmRunning() || helperBusy)
            }
            .sheet(isPresented: $permissions) { UbuntuGesturesPermissions() }
        }
    }

    private func change() {
        let enable = !on
        guard feature == "gestures" && enable else {
            update(["\(feature)=\(enable ? "on" : "off")"])
            return
        }
        installGestures()
    }

    private func update(_ features: [String]) {
        if let onUpdate { onUpdate(features) } else { state.updateVM(features: features) }
    }
    private func installGestures() {
        busy = true
        error = nil
        let script = Paths.scripts.appendingPathComponent("install-ubuntu-gestures.sh").path
        Task {
            let problem = await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script]
                do {
                    try p.run()
                    p.waitUntilExit()
                    return p.terminationStatus == 0 ? nil : "The Mac gestures helper could not be installed."
                } catch { return error.localizedDescription }
            }.value
            busy = false
            if let problem { error = problem }
            else { permissions = true; update(["gestures=on"]) }
        }
    }
}

/// The running helper publishes capabilities; permission flags alone do not prove failure.
struct UbuntuGesturesPermissions: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Checking the installed helper…"
    @State private var live: UbuntuGesturesStatus.Live?
    @State private var checking = false
    @State private var testStarted: Double?
    @State private var captureWindow = UserDefaults(suiteName: "org.omacvm.gestures")?.bool(forKey: "CaptureWindow") ?? false
    private let helper = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/UbuntuVMGestures.app")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Gestures & Permissions").font(.title2.bold())
                Spacer(); Button("Close") { dismiss() }
            }
            Text("Return to macOS: Control + Option + Escape (⌃⌥ Esc)").font(.headline)
            Text("The VM stays running. Press the shortcut again from macOS to return.")
            Picker("Capture gestures", selection: $captureWindow) {
                Text("Fullscreen only").tag(false)
                Text("Focused VM window too").tag(true)
            }.pickerStyle(.segmented)
            Text("Window capture is optional. Clicking another Mac app releases gestures. The setting applies to all VMs after the updated helper is installed.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(status).textSelection(.enabled)
            if let live {
                Text("Accessibility: \(live.accessibility ? "Allowed" : "Not allowed") · Input Monitoring: \(live.input ? "Allowed" : "Not reported allowed")")
                    .font(.caption).foregroundStyle(.secondary)
                if live.tap && !live.input {
                    Text("Input capture is active. A missing Input Monitoring flag does not mean your gestures are broken.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if !(live?.accessibility ?? status.contains("Accessibility: Allowed")) {
                    Button("Allow Accessibility…") { privacy("Privacy_Accessibility") }
                }
                if !(live?.input ?? status.contains("Input Monitoring: Allowed")) {
                    Button("Open Input Monitoring…") { privacy("Privacy_ListenEvent") }
                }
                Button("Check Again") { check() }.disabled(checking)
            }
            HStack {
                Button("Test a Swipe") { testStarted = Date().timeIntervalSince1970 }
                    .disabled(live?.tap != true || live?.connected != true)
                    .help("Requires the updated helper and a connected VM. Focus the VM once, then return here.")
                if let testStarted {
                    Text((live?.forwarded ?? 0) >= testStarted ? "Gesture sent to the VM. Did Ubuntu respond?" : "Focus the VM and swipe with three or four fingers, then return here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Helper and troubleshooting") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The background helper receives these grants. Select UbuntuVM Gestures in Settings.")
                    Text(helper.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Show Helper in Finder") { NSWorkspace.shared.activateFileViewerSelecting([helper]) }
                        Button("Copy Helper Path") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(helper.path, forType: .string)
                        }
                        Button("Restart Helper") { restart() }.disabled(checking)
                    }
                    Text("If the helper is absent from a privacy panel, click +, press Command–Shift–G and paste its path. If gestures fail despite an enabled entry, remove and re-add that exact helper. Working grants are never reset automatically by the updated Ubuntu helper.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }.padding(22).frame(width: 680)
        .onChange(of: captureWindow) { _, value in
            UserDefaults(suiteName: "org.omacvm.gestures")?.set(value, forKey: "CaptureWindow")
        }
        .task {
            while !Task.isCancelled {
                check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func privacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func restart() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/org.omacvm.gestures"]
        do { try p.run(); status = "Restart requested; checking automatically…" }
        catch { status = error.localizedDescription }
    }
    private func check() {
        guard !checking else { return }
        checking = true
        let executable = helper.appendingPathComponent("Contents/MacOS/omacvm-gestures")
        Task {
            let result = await Task.detached { () -> (String, UbuntuGesturesStatus.Live?) in
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return ("Helper not installed. Use Install Helper and Enable in VM settings.", nil)
                }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["print", "gui/\(getuid())/org.omacvm.gestures"]
                let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                    let launch = String(decoding: data, as: UTF8.self)
                    guard p.terminationStatus == 0,
                          let pid = launch.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                            .first(where: { $0.hasPrefix("pid = ") }).flatMap({ Int($0.dropFirst(6)) }) else {
                        return ("Helper is not running. Open troubleshooting to restart it.", nil)
                    }
                    let report = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/omacvm/gestures/status.json")
                    if let size = try? report.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink != true,
                       let count = size.fileSize, count <= 8192, let data = try? Data(contentsOf: report),
                       let value = UbuntuGesturesStatus.live(data, pid: pid) { return (value.summary, value) }
                    // Older helpers report only flags. Keep them neutral and target the missing grant.
                    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/omacvm-gestures.log")
                    let reader = try FileHandle(forReadingFrom: log)
                    defer { try? reader.close() }
                    let size = try reader.seekToEnd()
                    try reader.seek(toOffset: size > 262144 ? size - 262144 : 0)
                    let flags = UbuntuGesturesStatus.parse(String(decoding: reader.readDataToEndOfFile(), as: UTF8.self), pid: pid) ?? "Permission flags unavailable."
                    return (flags.replacingOccurrences(of: "Not granted", with: "Not reported allowed") + "\nLive diagnostics need the updated helper. If gestures work, keep using them; a missing permission flag alone is not a failure. Install the packaged helper from VM settings when convenient.", nil)
                } catch { return (error.localizedDescription, nil) }
            }.value
            status = result.0; live = result.1; checking = false
        }
    }
}
