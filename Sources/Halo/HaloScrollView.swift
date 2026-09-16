import SwiftUI

/// Shared sizing rules for Halo's bounded vertical rails.
///
/// Keeping these calculations outside SwiftUI makes scroll behavior easy to
/// reason about and test. A row height is optional because some future rails
/// may contain variable-height content; those rails still get the shared
/// maximum viewport and spacing rules.
enum HaloScrollMetrics {
    static let defaultMaximumHeight: CGFloat = 112
    static let defaultRowHeight: CGFloat = 30
    static let defaultRowSpacing: CGFloat = 10

    static func contentHeight(
        for itemCount: Int,
        rowHeight: CGFloat = defaultRowHeight,
        rowSpacing: CGFloat = defaultRowSpacing
    ) -> CGFloat {
        let count = max(0, itemCount)
        guard count > 0 else { return 0 }

        let safeRowHeight = max(0, rowHeight)
        let safeRowSpacing = max(0, rowSpacing)
        return CGFloat(count) * safeRowHeight
            + CGFloat(max(0, count - 1)) * safeRowSpacing
    }

    static func viewportHeight(
        for itemCount: Int,
        rowHeight: CGFloat = defaultRowHeight,
        rowSpacing: CGFloat = defaultRowSpacing,
        maximumHeight: CGFloat = defaultMaximumHeight
    ) -> CGFloat {
        min(
            contentHeight(for: itemCount, rowHeight: rowHeight, rowSpacing: rowSpacing),
            max(0, maximumHeight)
        )
    }

    static func needsScroll(
        for itemCount: Int,
        rowHeight: CGFloat = defaultRowHeight,
        rowSpacing: CGFloat = defaultRowSpacing,
        maximumHeight: CGFloat = defaultMaximumHeight
    ) -> Bool {
        contentHeight(for: itemCount, rowHeight: rowHeight, rowSpacing: rowSpacing)
            > max(0, maximumHeight)
    }
}

/// The standard vertical list container for Halo cards.
///
/// Feature views provide the data and row content. This component owns the
/// ScrollView, lazy stack, shared spacing, bounded viewport, and indicator
/// policy so every rail gets the same behavior by default.
struct HaloScrollView<Data: RandomAccessCollection, RowContent: View>: View
where Data.Element: Identifiable {
    private let items: Data
    private let maximumHeight: CGFloat
    private let rowHeight: CGFloat?
    private let rowSpacing: CGFloat
    private let rowContent: (Data.Element) -> RowContent

    init(
        items: Data,
        maximumHeight: CGFloat = HaloScrollMetrics.defaultMaximumHeight,
        rowHeight: CGFloat? = nil,
        rowSpacing: CGFloat = HaloScrollMetrics.defaultRowSpacing,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) {
        self.items = items
        self.maximumHeight = maximumHeight
        self.rowHeight = rowHeight
        self.rowSpacing = max(0, rowSpacing)
        self.rowContent = rowContent
    }

    @ViewBuilder
    var body: some View {
        if let rowHeight {
            scrollContent
                .frame(
                    height: HaloScrollMetrics.viewportHeight(
                        for: items.count,
                        rowHeight: rowHeight,
                        rowSpacing: rowSpacing,
                        maximumHeight: maximumHeight
                    ),
                    alignment: .top
                )
        } else {
            scrollContent
                .frame(maxHeight: max(0, maximumHeight), alignment: .top)
        }
    }

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(items) { item in
                    rowContent(item)
                }
            }
        }
        .scrollIndicators(.automatic)
    }
}
