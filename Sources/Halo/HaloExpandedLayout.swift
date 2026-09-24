import SwiftUI

/// Shared responsive measurements for content inside the expanded surface.
///
/// The notch can be resized by the user, but provider screens should not each
/// invent their own breakpoints. This layout keeps the common two-column
/// developer workspaces, calendar rail, and player rail inside the available
/// slot at every supported size.
struct HaloExpandedLayout: Equatable {
    let size: CGSize

    static let defaultSize = CGSize(width: 600, height: 136)

    var railWidth: CGFloat {
        min(190, max(124, size.width * 0.26))
    }

    var railViewportHeight: CGFloat {
        max(42, size.height - 28)
    }

    var playerArtworkSize: CGFloat {
        // The player is the most visual surface, so let taller notch sizes
        // give its artwork room instead of leaving an unused lower band.
        min(130, max(80, min(size.height * 0.66, size.height - 12)))
    }

    var playerRailViewportHeight: CGFloat {
        max(64, size.height)
    }

    var playerRailArtworkSize: CGFloat {
        min(48, max(36, size.height * 0.24))
    }

    var playerRailRowSpacing: CGFloat {
        min(10, max(8, size.height * 0.05))
    }

    var weatherGlyphSize: CGFloat {
        min(110, max(72, size.height * 0.80))
    }

    var playerRailWidth: CGFloat {
        min(200, max(145, size.width * 0.34))
    }

    var calendarNextColumnWidth: CGFloat {
        min(245, max(190, size.width * 0.38))
    }

    /// The conversation list shares space with its header, optional error or
    /// approval row, and the always-present composer.
    func messageViewportHeight(reservedHeight: CGFloat = 0) -> CGFloat {
        max(24, size.height - 68 - max(0, reservedHeight))
    }
}

private struct HaloExpandedLayoutKey: EnvironmentKey {
    static let defaultValue = HaloExpandedLayout(size: HaloExpandedLayout.defaultSize)
}

extension EnvironmentValues {
    var haloExpandedLayout: HaloExpandedLayout {
        get { self[HaloExpandedLayoutKey.self] }
        set { self[HaloExpandedLayoutKey.self] = newValue }
    }
}
