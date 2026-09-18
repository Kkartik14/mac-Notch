import Foundation

/// The only sources that are allowed to request an expansion. Ordinary
/// monitor updates use `.update` and never change the visible card.
enum HaloExpansionSource: Equatable {
    /// Explicit activity selection from a context menu or direct action. This
    /// creates a manual override for the expanded surface.
    case user
    /// The generic collapsed-pill tap. It opens the selected activity (or the
    /// current top activity when no override exists), but never replaces an
    /// explicit selection.
    case pillTap
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
        targetID: String,
        manualOverrideID: String? = nil
    ) -> Bool {
        switch intent {
        case .update:
            return false
        case .expand(.user):
            return true
        case .expand(.pillTap):
            guard currentExpandedID == nil else { return false }
            return manualOverrideID == nil || manualOverrideID == targetID
        case .expand(.hover):
            guard currentExpandedID == nil else { return false }
            return manualOverrideID == nil || manualOverrideID == targetID
        case .expand(.automatic):
            guard manualOverrideID == nil || manualOverrideID == targetID else { return false }
            return currentExpandedID == nil || currentExpandedID == targetID
        }
    }

    static func topActivityID(_ activities: [HaloActivity]) -> String? {
        activities.last?.id
    }

    static func topActivity(_ activities: [HaloActivity]) -> HaloActivity? {
        activities.last
    }

    /// The activity explicitly selected by the user owns the visible pill as
    /// well as the expanded card. Priority is only the fallback when there is
    /// no active selection override.
    static func selectedActivityID(
        _ activities: [HaloActivity],
        manualOverrideID: String?
    ) -> String? {
        if let manualOverrideID,
           activities.contains(where: { $0.id == manualOverrideID }) {
            return manualOverrideID
        }
        return topActivityID(activities)
    }

    static func selectedActivity(
        _ activities: [HaloActivity],
        manualOverrideID: String?
    ) -> HaloActivity? {
        guard let id = selectedActivityID(activities, manualOverrideID: manualOverrideID) else {
            return nil
        }
        return activities.first(where: { $0.id == id })
    }

    static func shouldCollapseOnPointerExit(
        expandedID: String?,
        collapseOnMouseLeave: Bool
    ) -> Bool {
        // An admin override owns the selected activity, not the pointer
        // lifecycle. Once the context-menu handoff is complete, leaving the
        // expanded surface must still minimize it normally.
        collapseOnMouseLeave && expandedID != nil
    }
}
