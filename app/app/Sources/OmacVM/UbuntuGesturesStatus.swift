import Foundation

/// Old log entries and another process's TCC identity must not look like
/// the running helper's permission state.
enum UbuntuGesturesStatus {
    static func parse(_ log: String, pid: Int) -> String? {
        let lines = log.split(separator: "\n")
        guard let start = lines.lastIndex(where: { $0.contains("omacvm-gestures: starting (pid ") }),
              lines[start].hasSuffix("starting (pid \(pid))"),
              let report = lines[start...].last(where: { $0.contains("omacvm-gestures: permissions: ") }) else { return nil }
        let ax = report.contains("Accessibility granted") ? "Allowed" : "Not granted"
        let input = report.contains("Input Monitoring granted") ? "Allowed" : "Not granted"
        return "Accessibility: \(ax)\nInput Monitoring: \(input)"
    }
}

extension UbuntuGesturesStatus {
    struct Live: Decodable {
        let schema: Int
        let pid: Int
        let updated: Double
        let accessibility: Bool
        let input: Bool
        let tap: Bool
        let trackpad: Bool
        let connected: Bool
        let capturing: Bool
        let forwarded: Double

        var summary: String {
            if !accessibility { return "Accessibility is needed for input capture." }
            if !tap { return "Input capture is not active. Restart the helper if it stays this way." }
            if !trackpad { return "Keyboard capture ready; no trackpad or Magic Mouse detected." }
            if !connected { return "Ready — waiting for a connected VM." }
            if capturing { return "Capture active — return to macOS with ⌃⌥ Esc." }
            return "Ready — focus a VM in the selected capture mode."
        }
    }

    static func live(_ data: Data, pid: Int, now: Double = Date().timeIntervalSince1970) -> Live? {
        guard data.count <= 8192, let value = try? JSONDecoder().decode(Live.self, from: data),
              value.schema == 1, value.pid == pid, value.updated >= now - 10, value.updated <= now + 5,
              value.forwarded >= 0, value.forwarded <= now + 5 else { return nil }
        return value
    }
}
