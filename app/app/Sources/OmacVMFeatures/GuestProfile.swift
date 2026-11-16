import Foundation

/// Guest identity is per VM. The app's bundle identity only selects its UI and installer.
public enum GuestProfile: String, CaseIterable, Identifiable, Sendable {
    case ubuntu, omarchy, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .ubuntu: "Ubuntu"; case .omarchy: "Omarchy"; case .custom: "Custom ISO" }
    }
    public var integrated: Bool { self != .custom }
    public var summary: String {
        switch self {
        case .ubuntu: "Ubuntu Desktop 26.10 ARM64 with GNOME integrations."
        case .omarchy: "Omarchy on Arch Linux ARM with the full OmacVM integration suite."
        case .custom: "Manual installation from an ARM64 UEFI ISO. Basic virtual hardware; no shared Mac files or guest setup."
        }
    }

    /// Only new VMs use these defaults. Existing feature choices are never rewritten.
    public func defaults(catalog: String, hasBattery: Bool, hasNotch: Bool) -> String {
        catalog.split(separator: "\n").compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let name = String(fields[0])
            let on: Bool
            switch self {
            case .custom: on = false
            case .ubuntu: on = ["gpu-compute", "camera", "drag-drop"].contains(name) || (name == "battery" && hasBattery)
            case .omarchy:
                on = fields[1] == "on" || (fields[1] == "notch" && hasNotch) || (fields[1] == "laptop" && hasBattery)
            }
            return name + "=" + (on ? "on" : "off")
        }.joined(separator: " ")
    }
}
