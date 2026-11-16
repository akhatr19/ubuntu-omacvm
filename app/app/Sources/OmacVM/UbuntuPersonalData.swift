import Darwin
import Foundation

/// Shares the CLI's registry lock until the desktop process has been spawned.
enum UbuntuPersonalData {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "UbuntuVM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func canonical(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(path) }
        return String(cString: path)
    }

    static func record(_ file: URL) throws -> [String: Any] {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16384,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              object["schema"] as? Int == 1 else { throw failure("Invalid personal data metadata.") }
        return object
    }

    static func start(_ config: VMConfig) throws -> (Int32, [String]) {
        let fm = FileManager.default
        let root = config.folder.deletingLastPathComponent().appendingPathComponent(".ubuntu-data")
        if fm.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw failure("Personal data storage must be a local directory.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot lock personal data storage.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw failure("Another data operation is running. Wait for it to finish.")
        }
        do {
            let file = config.folder.appendingPathComponent("data-volume.json")
            var info = stat()
            if lstat(file.path, &info) != 0 {
                guard errno == ENOENT else { throw failure("Cannot read personal data attachment.") }
                return (fd, [])
            }
            let binding = try record(file)
            guard binding["ready"] as? Bool == true, !fm.fileExists(atPath: config.folder.appendingPathComponent("data-needs-setup").path) else {
                throw failure("Finish personal data setup in Workbench → Files before starting this VM.")
            }
            guard let id = binding["id"] as? String, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
                throw failure("Invalid personal data ID.")
            }
            let folder = root.appendingPathComponent(id)
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw failure("Personal data folder is a symlink.") }
            let volume = try record(folder.appendingPathComponent("volume.json"))
            let disk = folder.appendingPathComponent("data.img")
            let values = try disk.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            let owner = (volume["attached_vm"] as? String).map { canonical(URL(fileURLWithPath: $0)) }
            guard volume["id"] as? String == id, owner == canonical(config.folder),
                  let size = volume["size_gb"] as? Int, (4...4096).contains(size),
                  values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == size * 1024 * 1024 * 1024 else {
                throw failure("Personal data is missing or its ownership changed. Attach the disk again in Workbench → Files.")
            }
            let path = disk.path.replacingOccurrences(of: ",", with: ",,")
            return (fd, ["-drive", "if=none,id=personal,file=\(path),format=raw,cache=writeback,discard=unmap",
                         "-device", "virtio-blk-pci,drive=personal,serial=UVM\(id.prefix(16))",
                         "-smbios", "type=11,value=uvm.data=\(id)"])
        } catch { close(fd); throw error }
    }
}
