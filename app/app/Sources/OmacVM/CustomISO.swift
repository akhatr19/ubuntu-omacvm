import CryptoKit
import Foundation

/// Manual installers get ordinary virtual hardware and no host integrations.
enum CustomISO {
    static func attached(_ config: VMConfig) -> Bool {
        FileManager.default.fileExists(atPath: config.folder.appendingPathComponent("install-iso").path)
    }

    static func prepare(folder: URL, iso: URL, diskGB: Int) throws {
        let fm = FileManager.default
        let values = try iso.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, iso.pathExtension.lowercased() == "iso",
              let size = values.fileSize, size >= 1024 * 1024, size <= 32 * 1024 * 1024 * 1024,
              (16...4096).contains(diskGB) else { throw HelperError.io("Choose an ARM64 UEFI ISO (up to 32 GB).") }
        let created = ["disk.img", "efi-vars.fd", "installer.iso", "iso-source.json", "install-iso", "home-folders-off", "ready"]
        guard created.allSatisfy({ !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            throw HelperError.io("This VM already has disk or installation files. Create a new VM instead.")
        }
        var complete = false
        defer { if !complete { for name in created { try? fm.removeItem(at: folder.appendingPathComponent(name)) } } }
        // A private copy pins the media even if the original download changes or is removed.
        let media = folder.appendingPathComponent("installer.iso")
        try fm.copyItem(at: iso, to: media)
        let incoming = try FileHandle(forReadingFrom: media)
        defer { try? incoming.close() }
        try incoming.seek(toOffset: 16 * 2048)
        let descriptors = try incoming.read(upToCount: 32 * 2048) ?? Data()
        guard stride(from: 0, to: max(0, descriptors.count - 6), by: 2048).contains(where: {
            descriptors.subdata(in: ($0 + 1)..<($0 + 6)) == Data("CD001".utf8)
        }) else { throw HelperError.io("This file is not a bootable ISO image. Choose an ARM64 UEFI installer.") }
        try incoming.seek(toOffset: 0)
        var hash = SHA256()
        while let block = try incoming.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        let record: [String: Any] = ["schema": 1, "target_architecture": "aarch64", "source": iso.lastPathComponent,
                                   "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(), "size": size]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: folder.appendingPathComponent("iso-source.json"), options: .atomic)
        for (name, bytes) in [("disk.img", UInt64(diskGB) * 1024 * 1024 * 1024), ("efi-vars.fd", UInt64(64 * 1024 * 1024))] {
            guard fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HelperError.io("Cannot create " + name) }
            let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(name))
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
        }
        for name in ["install-iso", "home-folders-off", "ready"] {
            try Data().write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        complete = true
    }

    static func arguments(_ config: VMConfig, base: [String]) -> [String] {
        var result = base.map { value in
            if value.hasPrefix("virtio-gpu-gl-pci,") { return "virtio-gpu-pci,max_outputs=1,xres=1280,yres=800" }
            if value.hasPrefix("cocoa,") { return "cocoa,gl=off,show-cursor=on,zoom-to-fit=on,full-screen=off,full-grab=off" }
            if value.hasPrefix("hda-micro,") { return "hda-output,bus=hda0.0,audiodev=snd0" }
            if attached(config) && value == "nvme,serial=omacvm,drive=disk,bootindex=0" { return "nvme,serial=omacvm,drive=disk,bootindex=1" }
            return value
        }
        // Optional qemu-ga is useful for identifying a supported Linux install later.
        let socket = config.agentSocket.path.replacingOccurrences(of: ",", with: ",,")
        result += ["-device", "virtio-serial-pci,id=custom-serial", "-chardev", "socket,id=qga,path=\(socket),server=on,wait=off",
                   "-device", "virtserialport,chardev=qga,name=org.qemu.guest_agent.0"]
        if attached(config) {
            let media = config.folder.appendingPathComponent("installer.iso").path.replacingOccurrences(of: ",", with: ",,")
            result += ["-device", "virtio-scsi-pci,id=install-scsi", "-drive", "if=none,id=install,file=\(media),format=raw,media=cdrom,readonly=on",
                       "-device", "scsi-cd,bus=install-scsi.0,drive=install,bootindex=0"]
        }
        return result
    }
}
