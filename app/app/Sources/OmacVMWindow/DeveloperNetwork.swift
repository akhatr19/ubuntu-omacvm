import Foundation

public struct DeveloperPort: Codable, Equatable, Sendable {
    public var host: Int
    public var guest: Int
    public var lan: Bool
    public init(host: Int = 3000, guest: Int = 3000, lan: Bool = false) {
        self.host = host; self.guest = guest; self.lan = lan
    }
    public var bind: String { lan ? "0.0.0.0" : "127.0.0.1" }
    public var qemu: String { "hostfwd=tcp:\(bind):\(host)-:\(guest)" }
}

public struct DeveloperNetwork: Codable, Equatable, Sendable {
    public var schema = 1
    public var sshLAN = false
    public var sshPort = 2222
    public var ports: [DeveloperPort] = []
    public var autoPorts = false
    public var idleMinutes: Int?
    public var publicKeys = ""
    public init() {}
    enum CodingKeys: String, CodingKey {
        case schema, ports
        case sshPort = "ssh_port", sshLAN = "ssh_lan", autoPorts = "auto_ports", idleMinutes = "idle_minutes", publicKeys = "public_keys"
    }
    public static let file = "developer-network.json"
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(ports, forKey: .ports)
        try c.encode(sshLAN, forKey: .sshLAN); try c.encode(sshPort, forKey: .sshPort)
        try c.encode(autoPorts, forKey: .autoPorts); try c.encode(publicKeys, forKey: .publicKeys)
        if let idleMinutes { try c.encode(idleMinutes, forKey: .idleMinutes) }
        else { try c.encodeNil(forKey: .idleMinutes) }
    }
    public func problem(sshPort: Int) -> String? {
        guard schema == 1, (1024...65535).contains(sshPort) else { return "SSH port must be 1024–65535." }
        guard ports.count <= 64 else { return "At most 64 forwards are supported." }
        guard (1024...65535).contains(self.sshPort) else { return "LAN SSH port must be 1024–65535." }
        var seen: Set<Int> = [sshPort]
        if sshLAN && !seen.insert(self.sshPort).inserted { return "LAN SSH and management ports must differ." }
        for port in ports {
            if port.guest == 22 { return "Configure guest port 22 in the SSH section." }
            guard (1024...65535).contains(port.host), (1...65535).contains(port.guest) else { return "Invalid forwarded port." }
            guard seen.insert(port.host).inserted else { return "Host ports must be unique, including SSH." }
        }
        if let idleMinutes, !(1...1440).contains(idleMinutes) { return "Idle timeout must be 1–1440 minutes." }
        guard publicKeys.utf8.count <= 16384 else { return "Public keys must fit in 16 KiB." }
        let lines = publicKeys.split(whereSeparator: \.isNewline).filter {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !value.hasPrefix("#")
        }
        guard lines.count <= 32 else { return "At most 32 public keys are supported." }
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"].contains(String(parts[0])),
                  let data = Data(base64Encoded: String(parts[1])), data.count >= 16 else { return "Paste public SSH keys, without options or private keys." }
            let size = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size <= data.count - 4, let kind = String(data: data.dropFirst(4).prefix(size), encoding: .utf8), kind == String(parts[0]) else { return "Public key type does not match its data." }
        }
        return nil
    }
    public static func read(folder: URL) throws -> Self {
        let path = folder.appendingPathComponent(file)
        var settings = Self()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("uvm-env.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manifest = object["manifest"] as? [String: Any] {
            settings.autoPorts = manifest["auto_ports"] as? Bool ?? true
            settings.idleMinutes = manifest["idle_minutes"] as? Int
            settings.ports = (manifest["ports"] as? [[String: Int]] ?? []).compactMap {
                guard let host = $0["host"], let guest = $0["guest"] else { return nil }
                return DeveloperPort(host: host, guest: guest)
            }
        }
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 32769) ?? Data()
            guard data.count <= 32768,
                  let override = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(override.keys).isSubset(of: ["schema", "ssh_lan", "ssh_port", "ports", "auto_ports", "idle_minutes", "public_keys"]) else { throw CocoaError(.fileReadCorruptFile) }
            var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
            merged.merge(override) { _, new in new }
            settings = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged))
        }
        return settings
    }
}
