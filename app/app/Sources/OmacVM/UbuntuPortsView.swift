import AppKit
import OmacVMWindow
import SwiftUI

struct UbuntuPortsView: View {
    @ObservedObject var state: AppState
    let config: VMConfig
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DeveloperNetwork()
    @State private var livePorts: [DeveloperPort] = []
    @State private var conflicts: Set<Int> = []
    @State private var checks: [Int: String] = [:]
    @State private var editing = false
    @State private var problem: String?
    @State private var running = false

    private var ports: [DeveloperPort] {
        let configured = settings.ports
        return configured + livePorts.filter { live in !configured.contains { $0.host == live.host } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ports & SSH — \(config.name)").font(.title2.bold())
                Spacer()
                Button("SSH Keys & Settings…") { editing = true }
                Button("Close") { dismiss() }
            }
            Text("Only this Mac means localhost. LAN sharing uses your Mac's IP and a separate port for each VM.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            Text(running ? "Ubuntu is running. Configure new forwards while it is stopped; they publish on the next start." : "Ubuntu is stopped. Configured services will publish at its next start.").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("SSH") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("From this Mac: SSH port \(config.sshPort)")
                                Spacer()
                                Button("Open Terminal") {
                                    do { try DeveloperActions.terminal(config, path: "/home/\(config.user)") }
                                    catch { problem = error.localizedDescription }
                                }
                            }
                            if settings.sshLAN {
                                Text("LAN SSH enabled on port \(settings.sshPort)").font(.headline)
                                ForEach(UbuntuNetworking.lanAddresses, id: \.self) { address in
                                    let command = "ssh -p \(settings.sshPort) \(config.user)@\(address)"
                                    HStack { Text(command).font(.system(.caption, design: .monospaced)); Spacer(); Button("Copy") { copy(command) } }
                                }
                            } else { Text("Other devices: SSH sharing is off. Enable it in SSH Keys & Settings.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    ForEach(ports, id: \.host) { port in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Ubuntu port \(port.guest) → Mac port \(port.host)").font(.headline)
                                    Spacer(); Text(port.lan ? "LAN shared" : "Only this Mac").foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Open localhost:\(port.host)") { browser("127.0.0.1", port.host) }
                                    Button("Copy Local URL") { copy("http://127.0.0.1:\(port.host)") }
                                    Button("Test Port") { test(port) }
                                }
                                if port.lan {
                                    ForEach(UbuntuNetworking.lanAddresses, id: \.self) { address in
                                        HStack { Text("http://\(address):\(port.host)").font(.system(.caption, design: .monospaced)); Spacer(); Button("Copy LAN URL") { copy("http://\(address):\(port.host)") } }
                                    }
                                }
                                if conflicts.contains(port.host) { Text("Mac port \(port.host) is occupied. Choose a different host port in settings.").foregroundStyle(.red) }
                                if let result = checks[port.host] { Text(result).font(.caption).foregroundStyle(.secondary) }
                            }.padding(6)
                        }
                    }
                    if ports.isEmpty { Text("No published services. Add a forward in settings, or enable automatic discovery for a developer environment.").padding(.vertical, 16) }
                }
            }
            Text("Open uses HTTP; for databases and other protocols use the displayed address in your client. A successful local test does not verify access from another LAN device.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 760, height: 620)
        .task {
            while !Task.isCancelled {
                refresh()
                let folder = config.folder
                let busy = await Task.detached { !Storage.busyFolders([folder]).isEmpty }.value
                if Task.isCancelled { return }
                running = busy
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $editing, onDismiss: refresh) { DeveloperSettingsView(state: state, config: config) }
    }
    private func refresh() {
        do { settings = try UbuntuNetworking.read(config); problem = nil } catch { problem = error.localizedDescription }
        let live = UbuntuNetworking.runtimeState(config)
        conflicts = Set(live?["conflicts"] as? [Int] ?? [])
        livePorts = (live?["ports"] as? [[String: Any]] ?? []).prefix(128).compactMap {
            guard let host = $0["host"] as? Int, let guest = $0["guest"] as? Int, (1024...65535).contains(host), (1...65535).contains(guest) else { return nil }
            return DeveloperPort(host: host, guest: guest, lan: $0["bind"] as? String == "0.0.0.0")
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func browser(_ host: String, _ port: Int) { if let url = URL(string: "http://\(host):\(port)") { NSWorkspace.shared.open(url) } }
    private func test(_ port: DeveloperPort) {
        checks[port.host] = "Checking localhost…"
        Task {
            let reachable = await Task.detached { UbuntuNetworking.portReachable(port.host) }.value
            checks[port.host] = reachable ? "Mac port is reachable. Use Open to check the application response." : "Mac port is not reachable. Start Ubuntu and check its service is listening."
        }
    }
}
