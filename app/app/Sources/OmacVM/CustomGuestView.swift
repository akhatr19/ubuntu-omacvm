import AppKit
import OmacVMFeatures
import SwiftUI

struct CustomGuestView: View {
    @ObservedObject var state: AppState
    let config: VMConfig
    let running: Bool
    @State private var attached = false
    @State private var checking = false
    @State private var candidate: GuestProfile?
    @State private var user = ""
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Custom ARM64 guest").font(.title2.bold())
                Text("Install the OS in its own installer. This VM has a basic display, network, audio output and dynamic-memory device. Advanced graphics and memory reclamation depend on the guest’s drivers.")
                GroupBox("Installation media") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(attached ? "Installer ISO attached. Next start boots the installer." : "Booting from the installed disk.")
                        Button(attached ? "Installation Finished — Eject ISO" : "Attach Installer Again") {
                            do {
                                let marker = config.folder.appendingPathComponent("install-iso")
                                if attached { try FileManager.default.removeItem(at: marker) }
                                else { try Data().write(to: marker, options: .atomic) }
                                attached.toggle()
                            } catch { message = error.localizedDescription }
                        }.disabled(running)
                        Text("Shut down the guest before changing media. The private ISO copy and its SHA-256 record stay with this VM.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Optional Linux integration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mac folders, clipboard, gestures and developer connections are off. After installation, you can enable the Ubuntu or Omarchy integration profile if the guest supports it.")
                        Text("Enable qemu-guest-agent and the OpenSSH server in Linux first. Detection reads guest identity; it does not install packages or expose Mac files.").font(.caption).foregroundStyle(.secondary)
                        Button("Detect Installed Linux") { detect() }.disabled(!running || checking || attached)
                        if let candidate {
                            Text("Detected \(candidate.title), user \(user). Enabling installs that profile’s guest integrations and enables ~/Linux sharing. Mac helpers may require your approval and permissions.")
                            Button("Enable \(candidate.title) Integration and Update VM…") { enable(candidate) }.disabled(running)
                            if running { Text("Shut down this VM to enable the detected profile.").font(.caption).foregroundStyle(.secondary) }
                        }
                        if checking { ProgressView("Reading guest identity…") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                if let message { Text(message).textSelection(.enabled).foregroundStyle(.secondary) }
            }.padding(22)
        }.onAppear { attached = CustomISO.attached(config) }
    }

    private func detect() {
        checking = true; message = nil; candidate = nil
        let agent = config.agentSocket.path
        Task {
            let result = await Task.detached {
                Result { try GuestIntegration.detect(agent: agent) }
            }.value
            checking = false
            switch result {
            case .success(let detected): candidate = detected.profile; user = detected.user
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func enable(_ guest: GuestProfile) {
        do {
            guard !running else { return }
            let updated = try GuestIntegration.configure(config, profile: guest, user: user)
            state.showOther(updated); state.showHome = false; state.updateVM()
        } catch { message = error.localizedDescription }
    }
}
