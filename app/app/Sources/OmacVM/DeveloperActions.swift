import AppKit
import SwiftUI

/// Developer environments share the CLI lifecycle, including when opened from the app.
enum DeveloperActions {
    static var cli: URL {
        URL(fileURLWithPath: TerminalCommand.appCLI).deletingLastPathComponent().appendingPathComponent("uvm")
    }

    static func name(_ config: VMConfig) -> String? {
        guard let data = try? Data(contentsOf: config.folder.appendingPathComponent("uvm-env.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              name.range(of: "^[a-z][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return nil }
        return name
    }

    static func command(_ config: VMConfig, _ action: String) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let root = config.folder.deletingLastPathComponent().path
        let test = config.folder.lastPathComponent.hasPrefix("OmacVM Test-Dev-") ? "1" : "0"
        return "env UVM_APP=\(quote(Bundle.main.bundleURL.path)) UVM_VMS_ROOT=\(quote(root)) UVM_TEST_MODE=\(test) \(quote(cli.path)) --env \(quote(name(config) ?? "dev")) \(action)"
    }

    static func open(_ config: VMConfig, _ action: String) throws {
        if let problem = Paths.startProblem(config.folder) {
            throw NSError(domain: "UbuntuVM", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-dev-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("UbuntuVM.command")
        // Remove the launcher after Terminal reads it; retain the environment and its logs.
        try ("#!/bin/bash\n/bin/rm -- \"$0\"\n/bin/rmdir -- \"$(dirname \"$0\")\"\n" + command(config, action) + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

struct DeveloperRow: View {
    @ObservedObject var state: AppState
    @State private var network = false
    @State private var environments = false

    var body: some View {
        SettingRow(title: "SSH & networking", subtitle: "Independent SSH, authorized public keys, LAN access and TCP port forwarding.", probe: "ubuntu-networking") {
            Button("Configure…") { network = true }
        }
        .sheet(isPresented: $network) { DeveloperSettingsView(state: state, config: state.config) }
        SettingRow(title: "Environments", subtitle: "Create and manage multiple Ubuntu environments. Headless VMs can run at the same time.", probe: "ubuntu-environments") {
            Button("Manage…") { environments = true }
        }
        .sheet(isPresented: $environments) { DeveloperEnvironmentsView(state: state) }
        if DeveloperActions.name(state.config) != nil {
            SettingRow(title: "Developer environment", subtitle: "Linux projects, editor connections and localhost ports use the same environment.", probe: "ubuntu-developer") {
                ForEach(["shell", "code", "ports", "stop"], id: \.self) { action in
                    Button(["shell": "Terminal", "code": "VS Code", "ports": "Ports", "stop": "Stop"][action]!) {
                        do { try DeveloperActions.open(state.config, action) }
                        catch { state.say(error.localizedDescription) }
                    }
                }
            }
        } else {
            SettingRow(title: "Developer CLI (uvm)", subtitle: "Optional command line tools. The GUI controls above do not require a CLI installation.", probe: "ubuntu-developer") {
                Button("Copy CLI Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DeveloperActions.cli.path, forType: .string)
                }
            }
        }
        SettingRow(title: "App location", subtitle: Bundle.main.bundleURL.path, probe: "ubuntu-app-location") {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        }
    }
}
