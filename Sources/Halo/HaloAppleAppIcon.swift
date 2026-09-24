import AppKit
import SwiftUI

/// Apple applications whose installed bundle artwork is used by Halo.
/// Loading the icon from the local app bundle keeps the mark current with
/// macOS instead of embedding or redrawing Apple's artwork.
enum HaloAppleApplication: String {
    case music = "com.apple.Music"
    case calendar = "com.apple.iCal"

    var fallbackSystemName: String {
        switch self {
        case .music: return "music.note"
        case .calendar: return "calendar"
        }
    }
}

enum HaloAppleAppIcon {
    static func image(for application: HaloAppleApplication) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.rawValue
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct HaloAppleAppIconView: View {
    let application: HaloAppleApplication
    let size: CGFloat

    var body: some View {
        if let image = HaloAppleAppIcon.image(for: application) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: application.fallbackSystemName)
                .font(.system(size: size * 0.82, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
                .frame(width: size, height: size)
        }
    }
}
