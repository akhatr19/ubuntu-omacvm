import AppKit
import OmacVMWindow
import SwiftUI

struct DeveloperSettingsView: View {
    @ObservedObject var state: AppState
    let config: VMConfig
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DeveloperNetwork()
    @State private var problem: String?
    @State private var busy = false
    @State private var loaded = false
    private var managed: Bool { DeveloperActions.name(config) != nil }
    private var key: String { config.folder.appendingPathComponent("ssh-key").path }
    private func ssh(_ host: String, port: Int, identity: Bool) -> String {
        "ssh " + (identity ? "-o IdentitiesOnly=yes -i '\(key.replacingOccurrences(of: "'", with: "'\\''"))' " : "") + "-p \(port) \(config.user)@\(host)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SSH & Networking — \(config.name)").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(busy || !loaded)
            }
            Text("Ubuntu is an independent VM using private NAT. LAN publication uses this Mac's address, not a separate router-assigned IP.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if busy { Text("Stop this VM before saving. Changes take effect at its next start.").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("SSH connection") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Private management SSH stays available to this Mac. Password login is disabled; use public keys.")
                            if FastNetwork.isOn(config) {
                                Text("Fast network uses the VM's private IP on port 22. Turn it off to use localhost and LAN publication below.").foregroundStyle(.orange)
                            } else {
                                commandRow("From this Mac", ssh("127.0.0.1", port: config.sshPort, identity: true))
                            }
                            Toggle("Allow SSH from other devices on the LAN", isOn: $settings.sshLAN)
                            if settings.sshLAN {
                                HStack { Text("LAN SSH port"); TextField("2222", value: $settings.sshPort, format: .number.grouping(.never)).frame(width: 90) }
                                ForEach(UbuntuNetworking.lanAddresses, id: \.self) { address in
                                    commandRow("From another device", ssh(address, port: settings.sshPort, identity: false))
                                }
                                Text("LAN ports listen on all Mac interfaces. The Mac firewall and network must permit incoming connections.").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Additional authorized public keys (one per line)").font(.headline)
                            TextEditor(text: $settings.publicKeys).font(.system(.caption, design: .monospaced)).frame(minHeight: 110)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                            Text("Paste the other device's .pub key. Existing guest keys and the private management key are preserved; private keys never belong here.").font(.caption).foregroundStyle(.secondary)
                            if !managed && busy {
                                Text(sshStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding(6)
                    }
                    GroupBox("TCP port forwarding") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A host port forwards to a port inside this VM. Each running VM needs different host ports.")
                            ForEach(settings.ports.indices, id: \.self) { index in
                                HStack {
                                    Text("Mac"); TextField("Host", value: $settings.ports[index].host, format: .number.grouping(.never)).frame(width: 85)
                                    Image(systemName: "arrow.right")
                                    Text("Ubuntu"); TextField("Guest", value: $settings.ports[index].guest, format: .number.grouping(.never)).frame(width: 85)
                                    Toggle("LAN", isOn: $settings.ports[index].lan)
                                    Button("Find Free Port") {
                                        var excluded = Set(settings.ports.enumerated().filter { $0.offset != index }.map { $0.element.host })
                                        excluded.insert(config.sshPort)
                                        if settings.sshLAN { excluded.insert(settings.sshPort) }
                                        if let free = UbuntuNetworking.availablePort(start: settings.ports[index].host, excluding: excluded) { settings.ports[index].host = free }
                                    }
                                    Button("Remove") { settings.ports.remove(at: index) }
                                }
                            }
                            Button("Add Forward") { settings.ports.append(DeveloperPort()) }.disabled(settings.ports.count >= 64)
                            if managed {
                                Toggle("Automatically forward detected developer ports to this Mac only", isOn: $settings.autoPorts)
                                Text("Automatic forwards stay local. Use an explicit LAN rule to share a service.").font(.caption).foregroundStyle(.secondary)
                                Text(busy ? UbuntuNetworking.runtimeStatus(config) : "Stopped — start this VM to publish its ports.").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }.padding(6)
                    }
                    if managed {
                        GroupBox("Headless lifecycle") {
                            HStack {
                                Toggle("Stop after idle", isOn: Binding(get: { settings.idleMinutes != nil }, set: { settings.idleMinutes = $0 ? 30 : nil }))
                                if settings.idleMinutes != nil {
                                    TextField("Minutes", value: Binding(get: { settings.idleMinutes ?? 30 }, set: { settings.idleMinutes = $0 }), format: .number.grouping(.never)).frame(width: 80)
                                    Text("minutes")
                                }
                            }.padding(6)
                        }
                    }
                }.disabled(busy)
            }
        }.padding(22).frame(width: 760, height: min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 110))
        .onAppear {
            do { settings = try UbuntuNetworking.read(config); loaded = true } catch { problem = error.localizedDescription }
            refreshBusy()
        }
        .onChange(of: state.tick) { _, _ in refreshBusy() }
    }
    private func refreshBusy() { busy = !Storage.busyFolders([config.folder]).isEmpty }
    private var sshStatus: String {
        let file = config.folder.appendingPathComponent("developer-network-status")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8192,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return "SSH keys and LAN publication are applied after Ubuntu boots." }
        return text
    }
    private func save() {
        do { try UbuntuNetworking.save(settings, config: config); problem = nil; dismiss() }
        catch { problem = error.localizedDescription; refreshBusy() }
    }
    private func commandRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
            }
        }
    }
}
