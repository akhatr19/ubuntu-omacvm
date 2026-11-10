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
