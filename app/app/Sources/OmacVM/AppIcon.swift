import AppKit
import OmacVMIcon
import SwiftUI

/// The app icon's look (IconTheme, org.omacvm.app appIconTheme): drawn for
/// the header, the Dock and QEMU's window (OMACVM_ICON: a PNG in the run
/// folder). In the Dock: the launcher's tile (NSApp.applicationIconImage, at
/// launch, when it changes and each time the launcher comes back after a VM:
/// macOS drops it when the app goes .accessory and back), QEMU's while the VM
/// runs, and the Dock tile plug-in's (OmacVMDockTile) while the app is not
/// running. The icon in the app bundle stays as it is.
@MainActor
enum AppIcon {
    static let changed = Notification.Name("OmacVM.AppIcon.changed")

    static var theme: IconTheme { IconTheme.choice(stored: Product.isUbuntu ? nil : UserDefaults.standard.object(forKey: IconTheme.key)) }

    static func set(_ t: IconTheme) {
        if t.isDefault {
            UserDefaults.standard.removeObject(forKey: IconTheme.key)
        } else {
            UserDefaults.standard.set(t.id, forKey: IconTheme.key)
        }
        apply()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The Dock's icon for this launch, and the plug-in's for when the app
    /// is not running (it reads the look again on this notice).
    static func apply() {
        let t = theme
        NSApp.applicationIconImage = t.isDefault ? nil : image(t, size: 1024)
        // On disk before the plug-in (another process) reads it.
        CFPreferencesAppSynchronize((Bundle.main.bundleIdentifier ?? "org.omacvm.app") as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(IconTheme.changedNotification), object: Bundle.main.bundleIdentifier,
            userInfo: nil, deliverImmediately: true)
    }

    /// The icon in a look, `size` points square.
    static func image(_ t: IconTheme, size: CGFloat) -> NSImage {
        if t.isDefault, let icon = bundleIcon { return icon }
        return IconArt.image(t, size: size)
    }

    /// The bundle's own icon (nil in `swift run`).
    private static let bundleIcon: NSImage? = Paths.icon.flatMap { NSImage(contentsOf: $0) }

    /// The PNG QEMU shows in the Dock while the VM runs; nil: the bundle's icon.
    static func fileForQEMU() -> URL? {
        let t = theme
        guard !t.isDefault else { return nil }
        let url = Paths.runDir.appendingPathComponent("icon-\(Bundle.main.bundleIdentifier ?? "omacvm")-\(t.id).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            guard let png = IconArt.bitmap(t, pixels: 1024)?.representation(using: .png, properties: [:]) else { return nil }
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// The header's icon: click it for the looks (two rows: dark, then light).
struct AppIconButton: View {
    var size: CGFloat = 32
    @State private var theme = AppIcon.theme
    @State private var open = false
    /// The window pictures: the popover's content drawn on its own.
    var preview: Bool = false

    var body: some View {
        Button { if !Product.isUbuntu { open.toggle() } } label: {
            Image(nsImage: AppIcon.image(theme, size: size))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help("\(Product.name)")
        .accessibilityLabel("\(Product.name) icon")
        .accessibilityHint(Product.isUbuntu ? "UbuntuVM" : "Shows other looks for the icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AppIconPicker(selected: theme) { t in
                AppIcon.set(t)
                theme = t
                open = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppIcon.changed)) { _ in theme = AppIcon.theme }
        .layoutProbe("app-icon")
    }
}

/// The eight looks: OmacVM's own and three dark Omarchy themes on top, four light ones below.
struct AppIconPicker: View {
    let selected: IconTheme
    let pick: (IconTheme) -> Void

    var body: some View {
        let rows = [IconTheme.all.filter(\.dark), IconTheme.all.filter { !$0.dark }]
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r]) { t in
                        Button { pick(t) } label: {
                            Image(nsImage: AppIcon.image(t, size: 36))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 36, height: 36)
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(t == selected ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(t.name)
                        .accessibilityLabel(t.name)
                        .accessibilityAddTraits(t == selected ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(10)
    }
}
