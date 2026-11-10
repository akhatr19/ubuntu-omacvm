import AppKit
import SwiftUI

/// Ubuntu features use its own installer; enabling gestures explicitly installs its Mac helper.
struct UbuntuFeatureRow: View {
    @ObservedObject var state: AppState
    let feature: String
    let title: String
    let detail: String
    @State private var busy = false
    @State private var error: String?
    @State private var permissions = false

    private var on: Bool { !VMRecord.isOff(feature, folder: state.config.folder) }

    var body: some View {
        SettingRow(title: title, subtitle: error ?? detail, subtitleIsError: error != nil, probe: "ubuntu-\(feature)") {
            if busy { ProgressView().controlSize(.small) }
            Button(on ? "Disable" : feature == "gestures" ? "Install Helper and Enable…" : "Enable") { change() }
                .disabled(busy || state.vmRunning())
        }
        if feature == "gestures" {
            SettingRow(title: "Gestures helper", subtitle: "Grant permissions to UbuntuVM Gestures, not the UbuntuVM launcher.", probe: "ubuntu-gesture-permissions") {
                Button("Set Up Permissions…") { permissions = true }
                Button("Repair Helper…") { installGestures() }.disabled(busy || state.vmRunning())
            }
            .sheet(isPresented: $permissions) { UbuntuGesturesPermissions() }
        }
    }

    private func change() {
        let enable = !on
        guard feature == "gestures" && enable else {
            state.updateVM(features: ["\(feature)=\(enable ? "on" : "off")"])
            return
        }
        installGestures()
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
            else { state.updateVM(features: ["gestures=on"]) }
        }
    }
}

/// Show permissions reported by the running helper, not its parent launcher.
struct UbuntuGesturesPermissions: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Checking the installed helper…"
    @State private var checking = false
    private let helper = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/UbuntuVMGestures.app")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("UbuntuVM Gestures permissions").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Give permissions to this helper. Selecting UbuntuVM.app, an old OmacVM helper, or a copy inside a build folder grants access to a different app.")
            Text(helper.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Show Exact Helper in Finder") { NSWorkspace.shared.activateFileViewerSelecting([helper]) }
                Button("Copy Helper Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(helper.path, forType: .string)
                }
            }
            Divider()
            Text("1. Open each privacy panel below. Click +, press Command–Shift–G, paste the helper path above, and select that app. Turn its switch on.")
            HStack {
                Button("Open Accessibility…") { privacy("Privacy_Accessibility") }
                Button("Open Input Monitoring…") { privacy("Privacy_ListenEvent") }
            }
            Text("2. If an older UbuntuVM Gestures or OmacVM Gestures entry is already enabled but access still fails, remove that entry with − and add the exact helper above again.")
            Text("3. After granting access, restart the helper and check again. Your VM does not need to be reinstalled.")
            HStack {
                Button("Restart Helper") { restart() }.disabled(checking)
                Button("Check Permissions Again") { check() }.disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            Text(status).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("Accessibility and Input Monitoring are separate grants. The status is reported by the running helper; macOS may permit some input through Accessibility even when Input Monitoring is off.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 680)
        .onAppear { check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func privacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func restart() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/org.omacvm.gestures"]
        do { try p.run(); status = "Restart requested. Check permissions again in a moment." }
        catch { status = error.localizedDescription }
    }
    private func check() {
        guard !checking else { return }
        checking = true
        let executable = helper.appendingPathComponent("Contents/MacOS/omacvm-gestures")
        Task {
            let result = await Task.detached { () -> String in
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return "Helper not installed. Close this panel and choose Repair Helper."
                }
                // A child spawned by this launcher can inherit its TCC
                // responsibility. Read the daemon's own report instead.
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
                        return "Helper is not running. Choose Restart Helper, then check again."
                    }
                    let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/omacvm-gestures.log")
                    let reader = try FileHandle(forReadingFrom: log)
                    defer { try? reader.close() }
                    let size = try reader.seekToEnd()
                    try reader.seek(toOffset: size > 262144 ? size - 262144 : 0)
                    return UbuntuGesturesStatus.parse(String(decoding: reader.readDataToEndOfFile(), as: UTF8.self), pid: pid)
                        ?? "Waiting for a current permission report. Restart the helper and check again."
                } catch { return error.localizedDescription }
            }.value
            status = result; checking = false
        }
    }
}
