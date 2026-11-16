import Foundation

/// External editor clients use this attestation instead of opening a second guest-agent connection.
enum GuestSSHIdentity {
    static func remember(_ config: VMConfig, agent: String, pid: pid_t) {
        guard case .exited(0, let output) = GuestAgent.runAndWait(socketPath: agent, "/bin/cat", ["/etc/ssh/ssh_host_ed25519_key.pub"], seconds: 5) else { return }
        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("ssh-ed25519 "), key.utf8.count <= 4096, !key.contains("\n") else { return }
        let value: [String: Any] = ["schema": 1, "pid": Int(pid), "key": key]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: config.folder.appendingPathComponent("logs/ssh-identity.json"), options: .atomic)
        }
    }
}
