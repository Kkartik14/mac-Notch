import Foundation

/// The only sources that are allowed to request an expansion. Ordinary
/// monitor updates use `.update` and never change the visible card.
enum HaloExpansionSource: Equatable {
    case user
    case hover
    case automatic
}

enum HaloPresentationIntent: Equatable {
    case update
    case expand(HaloExpansionSource)
}

/// Pure presentation rules shared by the center, pointer tracker, and tests.
/// Keeping these decisions out of individual monitors prevents each provider
/// from inventing its own expansion behavior.
enum HaloPresentationPolicy {
    static func shouldExpand(
        intent: HaloPresentationIntent,
        currentExpandedID: String?,
        targetID: String
    ) -> Bool {
        switch intent {
        case .update:
            return false
        case .expand(.user):
            return true
        case .expand(.hover):
            return currentExpandedID == nil
        case .expand(.automatic):
            return currentExpandedID == nil || currentExpandedID == targetID
        }
    }

    static func topActivityID(_ activities: [HaloActivity]) -> String? {
        activities.last?.id
    }

    static func topActivity(_ activities: [HaloActivity]) -> HaloActivity? {
        activities.last
    }

    static func shouldCollapseOnPointerExit(
        expandedID: String?,
        collapseOnMouseLeave: Bool
    ) -> Bool {
        collapseOnMouseLeave && expandedID != nil
    }
}
