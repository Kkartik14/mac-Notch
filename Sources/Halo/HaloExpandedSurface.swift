import SwiftUI

/// Shared shell for every expanded Halo screen.
///
/// The content receives only the space above the fixed app bar, so provider
/// screens cannot accidentally omit the bar or paint underneath it.
struct HaloExpandedSurface<Header: View, Content: View>: View {
    let destinations: [HaloDestination]
    let selectedID: String?
    let activities: [HaloActivity]
    let onSelectDestination: (HaloDestination) -> Void
    let header: Header
    let content: Content

    init(
        destinations: [HaloDestination],
        selectedID: String?,
        activities: [HaloActivity],
        onSelectDestination: @escaping (HaloDestination) -> Void,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.destinations = destinations
        self.selectedID = selectedID
        self.activities = activities
        self.onSelectDestination = onSelectDestination
        self.header = header()
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let headerHeight = max(24, haloClosedHeight)
            let destinationBarHeight = destinations.isEmpty
                ? 0
                : HaloDestinationBarMetrics.height
            let contentHeight = max(0, proxy.size.height - headerHeight - destinationBarHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(width: proxy.size.width, height: headerHeight, alignment: .leading)

                // This is an explicit finite slot. Provider views can keep
                // their natural layout, but they cannot push into the app bar.
                // Centering is relative to this slot — between the fixed
                // header and the fixed destination bar — rather than the
                // entire expanded Halo surface.
                content
                    .frame(width: proxy.size.width, height: contentHeight, alignment: .center)
                    .clipped()

                if !destinations.isEmpty {
                    HaloDestinationBar(
                        destinations: destinations,
                        selectedID: selectedID,
                        activities: activities,
                        onSelect: onSelectDestination
                    )
                    .frame(width: proxy.size.width, height: destinationBarHeight)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        // Anchor the destination bar directly to the lower edge of the notch.
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}
