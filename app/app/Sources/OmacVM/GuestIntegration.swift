import Foundation
import OmacVMFeatures

/// Detection is read-only. Changing profiles is an explicit stopped-VM operation.
enum GuestIntegration {
    static func detect(agent: String) throws -> (profile: GuestProfile, user: String) {
        let result = GuestAgent.runAndWait(socketPath: agent, "/bin/sh", ["-c", """
        . /etc/os-release
        if [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.10 ]; then echo ubuntu
        elif [ -d /usr/share/omarchy ]; then echo omarchy
        else echo unsupported; fi
        getent passwd 1000 | cut -d: -f1
        command -v sshd >/dev/null || exit 1
        systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service
        """], seconds: 10)
        guard case .exited(0, let output) = result else {
            throw HelperError.io("Guest detection needs a running Linux guest agent and SSH server.")
        }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 2, let profile = GuestProfile(rawValue: lines[0]), profile.integrated, lines[1] != "root",
              lines[1].range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            throw HelperError.io("This guest has no supported automatic integration profile. Basic VM operation remains available.")
        }
        return (profile, lines[1])
    }

    static func configure(_ config: VMConfig, profile: GuestProfile, user: String) throws -> VMConfig {
        guard config.isCustom, profile.integrated, user != "root", user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            throw HelperError.io("Choose a detected Linux profile and desktop account.")
        }
        guard Storage.busyFolders([config.folder]).isEmpty else { throw HelperError.io("Stop this VM before changing its integration profile.") }
        var updated = config
        updated.guest = profile; updated.user = user
        updated.features = VMConfig.defaultFeatures(for: profile)
        try updated.write()
        try (updated.features + "\n").write(to: updated.folder.appendingPathComponent("features"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: updated.folder.appendingPathComponent("home-folders-off"))
        return updated
    }
}
